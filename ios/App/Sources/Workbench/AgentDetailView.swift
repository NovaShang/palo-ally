import PaloAllyKit
import SwiftUI

/// What the title capsule opens (workbench-prd §6; the detail mock): a
/// contact card on top (state, name, folder, what it is doing), a row of
/// four big actions, then system grouped sections. Reads the store in the
/// environment: a session's own (`palStore`) or the assistant's. Palo's is
/// in `Detail/PaloDetailForm.swift`.
struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.tileDetail) private var tileDetail
    /// The list's content height, so a popover fits it (nil: not measured yet).
    @State private var contentHeight: CGFloat?

    private var asSheet: Bool { AgentDetailPlacement.usesSheet(model: model, store: store) }

    var body: some View {
        NavigationStack {
            Group {
                if store.scope == .palo {
                    PaloDetailForm()
                } else if let id = store.palID {
                    SessionDetailForm(palID: id)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, h in
                contentHeight = h
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if asSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { model.setDetail(false, tile: tileDetail) }.tint(.primary) }
                }
            }
        }
        // A popover takes its content's height (the navigation bar's 52 included), within reason.
        .frame(height: asSheet ? nil : contentHeight.map { min(max($0 + 52, 240), 640) })
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

    private var pal: Pal? { store.pal(id: palID) ?? detail?.pal }
    private var online: Bool { store.connection.isOnline }
    private var beside: Bool { UIDevice.current.userInterfaceIdiom != .phone }
    /// Asked again when the host says the session changed (`pals.updated`).
    private var refreshKey: String {
        "\(online)|\(pal?.updatedAt ?? 0)|\(pal?.attention.rawValue ?? "")|\(pal?.contextPct ?? -1)|\(pal?.model ?? "")|\(pal?.effort ?? "")"
    }

    var body: some View {
        List {
            if let failure {
                Section { Text(Copy.spaced(failure)).foregroundStyle(.red).font(.footnote) }
            }
            if let pal {
                top(pal)
                modelSection
                DetailContextSection(percent: contextPercent(pal), tokens: detail?.contextTokens, window: detail?.contextWindow,
                                     lastCompactAt: detail?.lastCompactAt,
                                     compact: { compact() },
                                     compacting: working == "compact",
                                     canCompact: online && working == nil && pal.status != .busy)
                tasks
                usageAndWorkspace(pal)
                end(pal)
            }
        }
        .navigationTitle("")
        .disabled(!online && detail == nil)
        .task(id: refreshKey) { await load() }
    }

    // MARK: header and actions

    private func top(_ pal: Pal) -> some View {
        Section {
            DetailHeader(indicator: AnyView(SessionIndicator(pal, size: 68)), name: pal.displayName,
                         folder: CCSession.shortPath(pal.cwd), line: statusLine(pal),
                         editing: $editing, draft: $newName, canRename: online,
                         onRename: { Task { await rename() } },
                         onBeginRename: { newName = pal.displayName; editing = true })
                .detailBare()
            DetailActionRow(actions: actions(pal)).detailBare()
        }
        .listSectionSpacing(.compact)
    }

    private func actions(_ pal: Pal) -> [DetailAction] {
        let idle = !online || working != nil
        let third = beside
            ? DetailAction(id: "terminal", title: Text("终端"), icon: "apple.terminal", enabled: !idle) { reveal("terminal") }
            : DetailAction(id: "compact", title: Text("压缩"), icon: "arrow.down.right.and.arrow.up.left",
                           enabled: !idle && pal.status != .busy) { compact() }
        return [
            DetailAction(id: "stop", title: Text("停止"), icon: "stop.fill", enabled: !idle && pal.status == .busy) { stopTurn() },
            DetailAction(id: "files", title: Text("文件", tableName: "Files"), icon: "folder") { openFiles() },
            third,
            DetailAction(id: "tile", title: Text("并排"), icon: "rectangle.split.2x1", enabled: online) { tile(pal) },
        ]
    }

    private func statusLine(_ pal: Pal) -> String {
        let status = StatusDot.label(pal.dot)
        if let a = pal.activity, pal.status == .busy, !a.isEmpty { return "\(status) · \(a)" }
        return "\(status) · \(Copy.palStatus(pal.status))"
    }

    // MARK: sections

    @ViewBuilder private var modelSection: some View {
        if let d = detail, !d.models.isEmpty {
            let current = d.models.first { $0.id == (d.model ?? pal?.model) }
            let efforts = current?.efforts ?? []
            let effort = d.effort ?? pal?.effort
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("思考深度").font(.callout)
                        Picker("思考深度", selection: Binding(get: { effort ?? efforts.first ?? "" },
                                                            set: { e in Task { await set(effort: e) } })) {
                            ForEach(efforts, id: \.self) { Text(EffortName.label($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(!online || working != nil)
                        .accessibilityIdentifier("detail-effort")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("模型")
            } footer: {
                Text("改了从下一轮开始生效。")
            }
        }
    }

    private func contextPercent(_ pal: Pal) -> Int? {
        if let t = detail?.contextTokens, let w = detail?.contextWindow, w > 0 { return Int((Double(t) / Double(w) * 100).rounded()) }
        return pal.contextPct
    }

    @ViewBuilder private var tasks: some View {
        if let list = detail?.tasks, !list.isEmpty {
            Section("正在跑 · \(list.count)") {
                ForEach(list) { t in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: t.kind == .subagent ? "person.2" : "terminal")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).lineLimit(2)
                            HStack(spacing: 4) {
                                Text(t.kind == .subagent ? String(localized: "子 agent") : String(localized: "后台任务"))
                                if t.startedAt > 0 { Text("·"); Text(t.startedAt.msDate, style: .relative) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if let s = t.summary, !s.isEmpty {
                                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("停", role: .destructive) { stop(t) }
                            .disabled(!online || working != nil)
                            .accessibilityIdentifier("detail-stop-\(t.id)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func usageAndWorkspace(_ pal: Pal) -> some View {
        let current = pal.workspaceId.flatMap { store.workspace(id: $0) }
        let others = store.workspaces.filter { $0.id != pal.workspaceId }
        Section("用量和工作区") {
            if let d = detail {
                LabeledContent("今天", value: DetailTokens.money(d.spentToday))
                LabeledContent("累计", value: DetailTokens.money(d.costTotalUsd))
            }
            if current != nil || !others.isEmpty {
                Menu {
                    ForEach(others) { w in
                        Button(w.title(pals: store.pals)) { move(to: w.id) }
                    }
                    if pal.workspaceId != nil {
                        Button("不放在工作区里") { move(to: nil) }
                    }
                } label: {
                    HStack {
                        Text("工作区").foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Text(current?.title(pals: store.pals) ?? String(localized: "无")).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .disabled(!online)
                .accessibilityIdentifier("detail-move")
            }
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
                    .frame(maxWidth: .infinity)
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

    private func stopTurn() {
        run("stop") { try await store.stop() }
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

    private func tile(_ pal: Pal) {
        model.setDetail(false, tile: tileDetail)
        // The sheet comes up once this one is gone.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            model.newWorkspace = [pal.id]
        }
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

// MARK: - in the chat

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
