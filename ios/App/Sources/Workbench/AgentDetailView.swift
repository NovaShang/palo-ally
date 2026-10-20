import PaloAllyKit
import SwiftUI

/// What the title's indicator opens (docs/workbench-design/details-v2.html):
/// a card that answers who it is and what it is doing at a glance (the
/// indicator, its name, folder and line), then its model, depth and
/// context, 停止 while it works, its tasks (what runs now, then 历史任务),
/// and for a session its usage, workspace and 结束. Files and 成果 are the
/// title bar's right button, not here. Reads the store in the environment:
/// a session's own (`palStore`) or the assistant's (Detail/PaloDetailForm).
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
                Section {
                    DetailHeader(indicator: AnyView(SessionIndicator(pal, size: 58, glass: false)), name: pal.displayName,
                                 caption: CCSession.shortPath(pal.cwd), line: statusLine(pal), state: pal.dot,
                                 editing: $editing, draft: $newName, canRename: online,
                                 onRename: { Task { await rename() } },
                                 onBeginRename: { newName = pal.displayName; editing = true })
                        .detailBare()
                }
                .listSectionSpacing(.compact)
                Section {
                    pickers
                    DetailContextRow(percent: contextPercent(pal), tokens: detail?.contextTokens, window: detail?.contextWindow,
                                     compact: { compact() }, compacting: working == "compact",
                                     canCompact: online && working == nil && pal.status != .busy)
                    if pal.status == .busy {
                        DetailStopRow(working: working == "stop") { stopTurn() }
                            .disabled(!online)
                    }
                }
                tasks
                usageAndWorkspace(pal)
                end(pal)
            }
        }
        .navigationTitle("")
        .disabled(!online && detail == nil)
        .task(id: refreshKey) { await load() }
    }

    private func statusLine(_ pal: Pal) -> String {
        if let a = pal.activity, pal.status == .busy, !a.isEmpty { return a }
        return StatusDot.label(pal.dot)
    }

    // MARK: sections

    /// 模型 and 思考深度: the system's pickers (a menu each).
    @ViewBuilder private var pickers: some View {
        let models = detail?.models ?? []
        let currentID = detail?.modelOption ?? detail?.model ?? pal?.model
        let current = models.first { $0.id == currentID }
        let efforts = detail?.efforts ?? []
        let effort = detail?.effort ?? pal?.effort
        Picker("模型", selection: Binding(get: { current?.id ?? currentID ?? "" },
                                         set: { m in Task { await set(model: m) } })) {
            if current == nil { Text(ModelName.short(currentID ?? "")).tag(currentID ?? "") }
            ForEach(models) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .detailNeutral()
        .disabled(!online || working != nil || models.isEmpty)
        .accessibilityIdentifier("detail-model")
        if !efforts.isEmpty {
            Picker("思考深度", selection: Binding(get: { effort ?? "" }, set: { e in Task { await set(effort: e) } })) {
                if effort.map({ !efforts.contains($0) }) ?? true { Text(EffortName.label(effort)).tag(effort ?? "") }
                ForEach(efforts, id: \.self) { Text(EffortName.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .detailNeutral()
            .disabled(!online || working != nil)
            .accessibilityIdentifier("detail-effort")
        }
    }

    private func contextPercent(_ pal: Pal) -> Int? {
        if let t = detail?.contextTokens, let w = detail?.contextWindow, w > 0 { return min(100, Int((Double(t) / Double(w) * 100).rounded())) }
        return pal.contextPct
    }

    /// What runs now (swipe to stop), then 历史任务.
    @ViewBuilder private var tasks: some View {
        let running = detail?.tasks ?? []
        Section {
            ForEach(running) { t in
                SessionTaskRow(task: t)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("停", role: .destructive) { stop(t) }
                            .disabled(!online || working != nil)
                            .accessibilityIdentifier("detail-stop-\(t.id)")
                    }
            }
            NavigationLink {
                SessionPastTasks(tasks: detail?.pastTasks ?? [])
            } label: {
                Text("历史任务")
            }
            .accessibilityIdentifier("detail-past-tasks")
        } header: {
            detailTasksHeader(running: running.count)
        }
    }

    @ViewBuilder private func usageAndWorkspace(_ pal: Pal) -> some View {
        let current = pal.workspaceId.flatMap { store.workspace(id: $0) }
        let others = store.workspaces.filter { $0.id != pal.workspaceId }
        Section {
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
                .tint(.primary)
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

    private func move(to workspaceID: String?) {
        run("move") { try await store.moveSession(palID, to: workspaceID) }
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

/// A subagent or background task of a session: what it is, since when, its latest line.
private struct SessionTaskRow: View {
    let task: PalTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.kind == .subagent ? "person.2" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(task.kind == .subagent ? String(localized: "子 agent") : String(localized: "后台任务"))
                    if let end = task.endedAt, end > 0 {
                        Text("·")
                        Text(Copy.relative(end))
                    } else if task.startedAt > 0 {
                        Text("·")
                        Text(task.startedAt.msDate, style: .relative)
                    }
                    if let status = task.status, status != .done {
                        Text("·")
                        Text(status == .failed ? String(localized: "没成") : String(localized: "停了"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let s = task.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }
}

/// 历史任务 of a session: the ones that ended, newest first.
private struct SessionPastTasks: View {
    let tasks: [PalTask]

    var body: some View {
        List {
            if tasks.isEmpty {
                ContentUnavailableView("还没有做完的任务", systemImage: "checklist",
                                       description: Text("它开的子 agent 和后台任务做完后会记在这里。"))
            } else {
                ForEach(tasks) { SessionTaskRow(task: $0) }
            }
        }
        .navigationTitle("历史任务")
        .navigationBarTitleDisplayMode(.inline)
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
