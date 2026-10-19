import PaloAllyKit
import SwiftUI

/// What the title capsule opens (workbench-prd §6): for a session its name,
/// state, folder, model and depth, context, background tasks, usage and
/// workspace, and 结束; for Palo the same shell with its model and its
/// 目标 / 履历 / 记忆 in short. Reads the store in the environment: a
/// session's own (`palStore`) or the assistant's.
struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.tileDetail) private var tileDetail

    var body: some View {
        NavigationStack {
            Group {
                if store.scope == .palo {
                    PaloDetailForm()
                } else if let id = store.palID {
                    SessionDetailForm(palID: id)
                }
            }
            .navigationTitle(store.scope == .palo ? store.assistantName : (store.palID.flatMap { store.pal(id: $0)?.displayName } ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if AgentDetailPlacement.usesSheet(model: model, store: store) {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { model.setDetail(false, tile: tileDetail) }.tint(.primary) }
                }
            }
        }
        .accessibilityIdentifier("agent-detail")
    }
}

// MARK: - a session

private struct SessionDetailForm: View {
    let palID: String
    @Environment(\.tileDetail) private var tileDetail
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var detail: PalDetail?
    @State private var failure: String?
    @State private var editing = false
    @State private var newName = ""
    @State private var working: String?
    @State private var confirmEnd = false
    @FocusState private var nameFocused: Bool

    private var pal: Pal? { store.pal(id: palID) ?? detail?.pal }
    private var online: Bool { store.connection.isOnline }
    private var beside: Bool { UIDevice.current.userInterfaceIdiom != .phone }
    /// Asked again when the host says the session changed (`pals.updated`).
    private var refreshKey: String {
        "\(online)|\(pal?.updatedAt ?? 0)|\(pal?.attention.rawValue ?? "")|\(pal?.contextPct ?? -1)|\(pal?.model ?? "")|\(pal?.effort ?? "")"
    }

    var body: some View {
        Form {
            if let failure {
                Section { Text(Copy.spaced(failure)).foregroundStyle(.red).font(.footnote) }
            }
            if let pal {
                header(pal)
                folder(pal)
                modelSection
                context(pal)
                tasks
                usage
                workspace(pal)
                end(pal)
            }
        }
        .disabled(!online && detail == nil)
        .task(id: refreshKey) { await load() }
    }

    // MARK: sections

    private func header(_ pal: Pal) -> some View {
        Section {
            if editing {
                HStack {
                    TextField("名字", text: $newName)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await rename() } }
                        .accessibilityIdentifier("detail-name-field")
                    Button("好") { Task { await rename() } }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack {
                    Text(pal.displayName).font(.headline).lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        newName = pal.displayName
                        editing = true
                        nameFocused = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .disabled(!online)
                    .accessibilityLabel("重命名")
                    .accessibilityIdentifier("detail-rename")
                }
            }
            HStack(spacing: 8) {
                StatusDot(pal.dot)
                Text(statusLine(pal)).foregroundStyle(.secondary).lineLimit(2)
            }
            .font(.subheadline)
        }
    }

    private func statusLine(_ pal: Pal) -> String {
        let status = StatusDot.label(pal.dot)
        if let a = pal.activity, pal.status == .busy, !a.isEmpty { return "\(status) · \(a)" }
        return "\(status) · \(Copy.palStatus(pal.status))"
    }

    private func folder(_ pal: Pal) -> some View {
        Section("文件夹") {
            Text(CCSession.shortPath(pal.cwd))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    openFiles()
                } label: {
                    Label { Text("文件", tableName: "Files") } icon: { Image(systemName: "folder") }
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("detail-files")
                if beside {
                    Button { reveal("finder") } label: { Label("访达", systemImage: "macwindow").frame(maxWidth: .infinity) }
                        .disabled(!online || working != nil)
                        .accessibilityIdentifier("detail-finder")
                    Button { reveal("terminal") } label: { Label("终端", systemImage: "apple.terminal").frame(maxWidth: .infinity) }
                        .disabled(!online || working != nil)
                        .accessibilityIdentifier("detail-terminal")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .controlSize(.regular)
        }
    }

    @ViewBuilder private var modelSection: some View {
        if let d = detail, !d.models.isEmpty {
            let current = d.models.first { $0.id == (d.model ?? pal?.model) }
            let efforts = current?.efforts ?? []
            Section {
                Menu {
                    ForEach(d.models) { m in
                        Button { Task { await set(model: m.id) } } label: {
                            if m.id == current?.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                        }
                    }
                } label: {
                    ModelRowLabel(title: Text("模型"), shown: current?.name ?? ModelName.short(d.model ?? pal?.model ?? ""))
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                .disabled(!online || working != nil)
                .accessibilityIdentifier("detail-model")
                if !efforts.isEmpty {
                    Menu {
                        ForEach(efforts, id: \.self) { e in
                            Button { Task { await set(effort: e) } } label: {
                                if e == (d.effort ?? pal?.effort) { Label(EffortName.label(e), systemImage: "checkmark") } else { Text(EffortName.label(e)) }
                            }
                        }
                    } label: {
                        ModelRowLabel(title: Text("思考深度"), shown: EffortName.label(d.effort ?? pal?.effort))
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .disabled(!online || working != nil)
                    .accessibilityIdentifier("detail-effort")
                }
            } footer: {
                Text("改了从下一轮开始生效。")
            }
        }
    }

    @ViewBuilder private func context(_ pal: Pal) -> some View {
        let pct = contextPercent(pal)
        if let pct {
            Section("上下文") {
                HStack(spacing: 10) {
                    ProgressView(value: Double(min(pct, 100)) / 100)
                        .tint(pct >= 85 ? .orange : .secondary)
                    Text("\(pct)%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    if let at = detail?.lastCompactAt, at > 0 {
                        Text("上次压缩 \(Copy.relative(at))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(working == "compact" ? String(localized: "正在压缩…") : String(localized: "压缩")) { compact() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.primary)
                        .disabled(!online || working != nil || pal.status == .busy)
                        .accessibilityIdentifier("detail-compact")
                }
            }
        }
    }

    private func contextPercent(_ pal: Pal) -> Int? {
        if let t = detail?.contextTokens, let w = detail?.contextWindow, w > 0 { return Int((Double(t) / Double(w) * 100).rounded()) }
        return pal.contextPct
    }

    @ViewBuilder private var tasks: some View {
        if let list = detail?.tasks, !list.isEmpty {
            Section("后台任务") {
                ForEach(list) { t in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: t.kind == .subagent ? "person.2" : "terminal")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).lineLimit(2)
                            Text(t.kind == .subagent ? String(localized: "子 agent") : String(localized: "后台任务"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let s = t.summary, !s.isEmpty {
                                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("停") { stop(t) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.primary)
                            .controlSize(.small)
                            .disabled(!online || working != nil)
                            .accessibilityIdentifier("detail-stop-\(t.id)")
                    }
                }
            }
        }
    }

    @ViewBuilder private var usage: some View {
        if let d = detail {
            Section("用量") {
                LabeledContent("今天", value: Self.money(d.spentToday))
                LabeledContent("累计", value: Self.money(d.costTotalUsd))
            }
        }
    }

    private static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    private func workspace(_ pal: Pal) -> some View {
        let current = pal.workspaceId.flatMap { store.workspace(id: $0) }
        return Section("工作区") {
            if let current {
                LabeledContent("现在在", value: current.title(pals: store.pals))
            }
            HStack(spacing: 8) {
                Button {
                    model.setDetail(false, tile: tileDetail)
                    // The sheet comes up once this one is gone.
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        model.newWorkspace = [pal.id]
                    }
                } label: {
                    Label("并排…", systemImage: "rectangle.split.2x1").frame(maxWidth: .infinity)
                }
                .disabled(!online)
                .accessibilityIdentifier("detail-tile")
                Menu {
                    ForEach(store.workspaces.filter { $0.id != pal.workspaceId }) { w in
                        Button(w.title(pals: store.pals)) { move(to: w.id) }
                    }
                    if pal.workspaceId != nil {
                        Button("不放在工作区里") { move(to: nil) }
                    }
                } label: {
                    Label("移到…", systemImage: "arrow.right.square").frame(maxWidth: .infinity)
                }
                .disabled(!online || (store.workspaces.filter { $0.id != pal.workspaceId }.isEmpty && pal.workspaceId == nil))
                .accessibilityIdentifier("detail-move")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
        }
    }

    @ViewBuilder private func end(_ pal: Pal) -> some View {
        Section {
            if confirmEnd {
                ConfirmPanel(title: Copy.spaced(String(localized: "结束「\(pal.displayName)」？")),
                             text: String(localized: "它会停下，进到「以前的」里，之后还能接着聊。"),
                             action: String(localized: "结束会话"), working: working == "end", glass: false,
                             cancel: { confirmEnd = false }, confirm: { endSession() })
            } else {
                Button("结束这个会话", role: .destructive) { confirmEnd = true }
                    .disabled(!online)
                    .accessibilityIdentifier("detail-end")
            }
        }
    }

    // MARK: actions

    private func load() async {
        guard online else { return }
        do {
            detail = try await store.palDetail(id: palID)
            failure = nil
        } catch {
            if detail == nil { failure = Copy.error(error) }
        }
    }

    private func run(_ key: String, _ op: @escaping () async throws -> Void) {
        working = key
        failure = nil
        Task {
            defer { working = nil }
            do { try await op() } catch { failure = Copy.error(error) }
        }
    }

    private func rename() async {
        let name = newName
        editing = false
        do { _ = try await store.renamePal(id: palID, name: name) } catch { failure = String(localized: "没改成：\(Copy.error(error))") }
    }

    private func set(model: String? = nil, effort: String? = nil) async {
        working = "model"
        defer { working = nil }
        do {
            try await store.setSessionModel(id: palID, model: model, effort: effort)
            detail = try await store.palDetail(id: palID)
        } catch {
            failure = Copy.error(error)
        }
    }

    private func compact() {
        run("compact") {
            try await store.compactSession(id: palID)
            detail = try? await store.palDetail(id: palID)
        }
    }

    private func stop(_ t: PalTask) {
        run("stop") {
            try await store.stopTask(id: palID, taskId: t.id)
            detail = try? await store.palDetail(id: palID)
        }
    }

    private func reveal(_ kind: String) {
        run("reveal") { try await store.revealSession(id: palID, kind: kind) }
    }

    private func move(to workspaceID: String?) {
        run("move") { try await store.moveSession(palID, to: workspaceID) }
    }

    private func openFiles() {
        model.setDetail(false, tile: tileDetail)
        let id = palID
        // On a phone the files come up as a sheet, once this one is gone.
        Task {
            try? await Task.sleep(for: .milliseconds(model.libraryBeside ? 0 : 400))
            model.openPalFiles(id)
        }
    }

    private func endSession() {
        run("end") {
            try await store.endSession(id: palID)
            model.setDetail(false, tile: tileDetail)
            // On its own page it is gone; in a tile the workspace carries on.
            if tileDetail == nil { model.showList() }
        }
    }
}

// MARK: - Palo

private struct PaloDetailForm: View {
    @Environment(\.tileDetail) private var tileDetail
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var memoryCount: Int?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 8) {
                    StatusDot(store.assistantWorking ? .working : .idle)
                    Text(store.assistantWorking ? (store.status?.activity ?? StatusDot.label(.working)) : StatusDot.label(.idle))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            Section {
                ModelRow { model.showModelPicker = true }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            }
            goals
            history
            Section("记忆") {
                Text(memoryCount.map { $0 > 0 ? String(localized: "它记着 \($0) 条") : String(localized: "还没记下什么") } ?? "…")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("查看全部") {
                    model.setDetail(false, tile: tileDetail)
                    model.openManagement()
                }
                .accessibilityIdentifier("detail-all")
            }
        }
        .sheet(isPresented: $model.showModelPicker) {
            ModelPickerSheet().environment(model).environment(store)
        }
        .task(id: model.memoryRevision) {
            memoryCount = (try? await store.memoryFiles())?.count
        }
    }

    @ViewBuilder private var goals: some View {
        let live = store.watches.filter { $0.state != .done }.prefix(3)
        Section("目标") {
            if live.isEmpty {
                Text("还没有目标").foregroundStyle(.secondary)
            }
            ForEach(Array(live)) { w in
                NavigationLink { GoalDetail(id: w.id) } label: { GoalRow(goal: w) }
            }
        }
    }

    @ViewBuilder private var history: some View {
        let active = store.tasks.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }.prefix(2)
        let done = store.tasks.filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3)
        Section("履历") {
            if active.isEmpty && done.isEmpty {
                Text("还没有办过的事").foregroundStyle(.secondary)
            }
            ForEach(Array(active)) { RunningHistoryRow(task: $0) }
            ForEach(Array(done)) { DoneHistoryRow(task: $0) }
        }
    }
}

// MARK: - in the chat

/// 「后台 N 个在跑」: one quiet line above the composer while the session has
/// background tasks or sub-agents running; tapping it opens the details.
struct BackgroundTasksLine: View {
    @Environment(\.tileDetail) private var tileDetail
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var count = 0

    private var pal: Pal? { store.palID.flatMap { store.pal(id: $0) } }

    var body: some View {
        Group {
            if count > 0 {
                Button { model.setDetail(true, tile: tileDetail) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.caption2)
                        Text("后台 \(count) 个在跑").font(.caption)
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityIdentifier("background-tasks")
            }
        }
        .animation(.snappy, value: count)
        // The host says when tasks change (`pals.updated`); asked then.
        .task(id: "\(store.connection.isOnline)|\(pal?.updatedAt ?? 0)|\(pal?.attention.rawValue ?? "")") {
            guard let id = store.palID, store.connection.isOnline else { return }
            count = (try? await store.palDetail(id: id).tasks.count) ?? count
        }
    }
}
