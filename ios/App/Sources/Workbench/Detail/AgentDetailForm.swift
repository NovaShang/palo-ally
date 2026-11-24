import PaloAllyKit
import SwiftUI

/// The details of an agent, the assistant's and a Pal's on one page
/// (docs/workbench-design/structure-wireframe.html §3): who it is and what it
/// is doing (the header), 现在 (what runs, the context), 定时 (the
/// assistant's), 设置 folded away (name, model and thinking, permission mode,
/// memory, workspace; the assistant's color and language), 记录, and at the
/// bottom 归档 (an agent) or 让助理停下. The data is one `AgentDetail`; what
/// one kind has and the other hasn't is its `capabilities`.
struct AgentDetailForm: View {
    /// A Pal's id; nil: the assistant.
    let agent: String?
    @Environment(\.tileDetail) private var tileDetail
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var palDetail: PalDetail?
    @State private var failure: String?
    @State private var editing = false
    @State private var newName = ""
    @State private var working: String?
    @State private var confirmEnd = false
    @State private var confirmStop = false
    @State private var inTerminal: Pal?
    @State private var copiedTerminal = false
    @State private var memoryCount: Int?

    private var online: Bool { store.connection.isOnline }
    private var pal: Pal? { agent.flatMap { store.pal(id: $0) ?? palDetail?.pal } }
    private var detail: AgentDetail? { agent == nil ? store.assistantDetail : palDetail.map { AgentDetail($0, harness: store.harness) } }
    private var caps: AgentDetail.Capabilities { agent == nil ? .assistant : .agent }
    /// Asked again when the host says the session changed (`pals.updated`).
    private var refreshKey: String {
        guard let pal else { return "\(online)" }
        return "\(online)|\(pal.updatedAt ?? 0)|\(pal.attention.rawValue)|\(pal.contextPct ?? -1)|\(pal.model ?? "")|\(pal.effort ?? "")|\(pal.permissionMode ?? "")"
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                // Unfolded below the fold: brought up so its rows show.
                .onChange(of: model.detailSettingsOpen) { _, open in
                    guard open else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(.snappy) { proxy.scrollTo(Self.settingsID, anchor: .top) }
                    }
                }
        }
        .navigationDestination(isPresented: Binding(get: { model.detailMemoryOpen }, set: { model.detailMemoryOpen = $0 })) {
            MemoryPage(agent: agent)
        }
    }

    private static let settingsID = "detail-settings-section"

    private var list: some View {
        List {
            if let failure {
                Section { Text(Copy.spaced(failure)).foregroundStyle(.red).font(.footnote) }
            }
            if agent == nil || pal != nil {
                Section { header }
                    .listSectionSpacing(.compact)
                now
                if caps.timers { WatchesSection() }
                settings
                history
                bottom
            }
        }
        .navigationTitle("")
        .disabled(agent != nil && !online && palDetail == nil)
        .task(id: refreshKey) { await load() }
        .task(id: "\(online)|\(model.memoryRevision)") { await countMemory() }
        .sheet(isPresented: Binding(get: { agent == nil && model.showIdentityEditor }, set: { model.showIdentityEditor = $0 })) {
            IdentityEditor(purpose: .edit).environment(model).environment(store)
        }
        .accessibilityIdentifier(agent == nil ? "management" : "agent-details")
    }

    // MARK: the header

    @ViewBuilder private var header: some View {
        if let agent, let pal {
            let line = AgentStatusLine.of(pal)
            DetailHeader(indicator: AnyView(SessionIndicator(pal, size: 46)), name: pal.displayName,
                         caption: agentCaption(pal), line: UsageText.stopped(pal, model.store ?? store) ?? line.text, state: UsageText.stopped(pal, model.store ?? store) == nil ? pal.dot : .idle,
                         editing: $editing, draft: $newName, canRename: online,
                         onRename: { Task { await rename(agent) } },
                         onBeginRename: { beginRename(pal) })
                .detailBare()
        } else {
            DetailHeader(indicator: AnyView(TitleOrbDrop(size: 46)), name: store.assistantName,
                         caption: assistantCaption, line: store.agentStatusLine.text, state: store.paloDot,
                         editing: .constant(false), draft: .constant(""),
                         onRename: {}, onBeginRename: { model.showIdentityEditor = true })
                .detailBare()
        }
    }

    /// 「~/code/shop · 工作区 重构」.
    private func agentCaption(_ pal: Pal) -> String {
        var parts = [CCSession.shortPath(pal.cwd)]
        if let w = pal.workspaceId.flatMap({ store.workspace(id: $0) }) {
            parts.append(String(localized: "工作区 \(w.title(pals: store.pals))"))
        }
        return parts.joined(separator: " · ")
    }

    /// 「住在「X」上 · 认识你 N 天」: where it lives and how long you've known each other.
    private var assistantCaption: String {
        let place = store.hostName.isEmpty ? (model.pairedHost?.hostLabel ?? "") : store.hostName
        var parts: [String] = []
        if !place.isEmpty { parts.append(String(localized: "住在「\(place)」上")) }
        if !store.displayedConnection.isOnline {
            parts.append(Copy.connection(store.displayedConnection))
        } else if let met = store.status?.metAt, met > 0 {
            let days = max(1, Int(Date().timeIntervalSince(met.msDate) / 86_400) + 1)
            parts.append(String(localized: "认识你 \(days) 天"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 现在

    @ViewBuilder private var now: some View {
        Section {
            ForEach(detail?.tasks ?? []) { t in
                AgentTaskRow(task: t)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if caps.stopTasks, let agent {
                            Button("停", role: .destructive) { stop(t, in: agent) }
                                .disabled(!online || working != nil)
                                .accessibilityIdentifier("detail-stop-\(t.id)")
                        }
                    }
            }
            DetailContextRow(percent: detail?.contextFill, tokens: detail?.contextTokens, window: detail?.contextWindow,
                             compact: caps.compact && store.harness.features.compact ? { compact() } : nil, compacting: working == "compact",
                             canCompact: online && working == nil && pal?.status != .busy)
        } header: {
            let n = detail?.tasks.count ?? 0
            Text(n > 0 ? String(localized: "现在 · 后台 \(n) 个任务") : String(localized: "现在"))
        }
    }

    // MARK: 设置

    @ViewBuilder private var settings: some View {
        Section {
            Button {
                withAnimation(.snappy) { model.detailSettingsOpen.toggle() }
            } label: {
                HStack {
                    Text("设置").foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    if !model.detailSettingsOpen {
                        Text(settingsSummary).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(model.detailSettingsOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            .accessibilityValue(model.detailSettingsOpen ? Text("已展开") : Text("已折起"))
            .accessibilityIdentifier("detail-settings")
            .id(Self.settingsID)
            if model.detailSettingsOpen {
                if caps.color {
                    ThemeSwatches(selection: themeBinding)
                }
                nameRow
                if caps.language { languagePicker }
                if let detail {
                    ModelPickers(detail: detail, disabled: !online || working != nil) { m, e in setModel(m, e) }
                }
                if let detail, let mode = detail.permissionMode, !detail.permissionModes.isEmpty {
                    permissionPicker(detail, mode: mode)
                }
                memoryRow
                if caps.workspace, let pal { workspaceRow(pal) }
            }
        } footer: {
            if model.detailSettingsOpen, caps.color {
                Text("颜色也是 App 和桌面图标的颜色。语言和手机的系统语言分开；自动：按第一台连上主机的设备的语言。")
            }
        }
    }

    /// What's under 设置 while it's folded: 「Opus 5.5 · 思考：深」.
    private var settingsSummary: String {
        guard let detail else { return "" }
        let name = detail.models.first { $0.id == detail.selectedModel }?.name ?? ModelName.short(detail.runningModel)
        guard let e = detail.effort, !e.isEmpty, !detail.efforts.isEmpty else { return name }
        return String(localized: "\(name) · 思考：\(detail.harness.effortLabel(e))")
    }

    private var nameRow: some View {
        Button {
            if let pal { beginRename(pal) } else { model.showIdentityEditor = true }
        } label: {
            HStack {
                Text(caps.color ? String(localized: "名字和颜色") : String(localized: "名字")).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(pal?.displayName ?? store.assistantName).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "pencil").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        // (An agent's name is its harness' title for it: only a harness that renames.)
        .disabled(agent != nil && (!online || !store.harness.features.rename))
        .accessibilityIdentifier("detail-name")
    }

    private var languagePicker: some View {
        Picker("说话用的语言", selection: languageBinding) {
            Text("自动").tag("")
            Text(verbatim: "中文").tag("zh")
            Text(verbatim: "English").tag("en")
        }
        .pickerStyle(.menu)
        .detailNeutral()
        .disabled(!online || store.settings == nil)
        .accessibilityIdentifier("detail-language")
    }

    /// 权限模式: a host that can't switch it sends none (the row hides).
    private func permissionPicker(_ detail: AgentDetail, mode: String) -> some View {
        Picker(selection: Binding(get: { mode }, set: { m in setMode(m, from: mode) })) {
            ForEach(detail.permissionModes, id: \.self) { Text(detail.harness.modeLabel($0)).tag($0) }
        } label: {
            Text("权限模式")
            // Claude Code may run in another (auto needs a model that has it).
            if let running = detail.runningMode {
                Text("现在实际是「\(detail.harness.modeLabel(running))」")
            }
        }
        .pickerStyle(.menu)
        .detailNeutral()
        .disabled(!online || working != nil)
        .accessibilityIdentifier("detail-permission-mode")
    }

    private var memoryRow: some View {
        Button { model.detailMemoryOpen = true } label: {
            HStack {
                LabeledContent(String(localized: "记忆"), value: memoryLine)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityIdentifier("detail-memory")
    }

    private var memoryLine: String {
        guard let memoryCount else { return "…" }
        return memoryCount > 0 ? String(localized: "\(memoryCount) 条") : String(localized: "还没记下什么")
    }

    /// 工作区: which one it's in, or none.
    @ViewBuilder private func workspaceRow(_ pal: Pal) -> some View {
        if !store.workspaces.isEmpty || pal.workspaceId != nil {
            Picker("工作区", selection: Binding(get: { pal.workspaceId ?? "" }, set: { w in
                guard w != (pal.workspaceId ?? "") else { return }
                move(pal.id, to: w.isEmpty ? nil : w)
            })) {
                Text("无").tag("")
                ForEach(store.workspaces) { Text($0.title(pals: store.pals)).tag($0.id) }
            }
            .pickerStyle(.menu)
            .detailNeutral()
            .disabled(!online || working != nil)
            .accessibilityIdentifier("detail-move")
        }
    }

    // MARK: 记录

    /// The latest few that ended, then the whole list.
    @ViewBuilder private var history: some View {
        let past = detail?.pastTasks ?? []
        Section {
            if past.isEmpty {
                Text(agent == nil ? String(localized: "还没有记录。交代的事做完会记在这里。")
                                  : String(localized: "还没有记录。它开的子 agent 和后台任务做完后会记在这里。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(past.prefix(3)) { AgentTaskRow(task: $0) }
            if past.count > 3 {
                NavigationLink {
                    HistoryPage(agent: agent, tasks: past)
                } label: {
                    Text("全部记录 · \(past.count)")
                }
                .accessibilityIdentifier("detail-past-tasks")
            }
        } header: {
            Text("记录")
        }
    }

    // MARK: 在终端打开, 归档 / 让助理停下

    /// Its session in a terminal on this Mac, or the line for it to copy.
    @ViewBuilder private func terminalRow(_ pal: Pal) -> some View {
        if store.terminalSupported, !pal.openInTerminal {
            Button { inTerminal = pal } label: {
                if AgentTerminal.opensHere(store) {
                    Text("在终端打开")
                } else {
                    Text(copiedTerminal ? String(localized: "已复制") : String(localized: "复制终端命令"))
                }
            }
            .tint(.primary)
            .frame(maxWidth: .infinity)
            // (The line under it spans the card: the words are in its middle.)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .disabled(!online)
            .accessibilityIdentifier("detail-terminal")
            .agentTerminal($inTerminal) { copiedTerminal = true }
            .task(id: copiedTerminal) {
                guard copiedTerminal else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copiedTerminal = false
            }
        }
    }

    @ViewBuilder private var bottom: some View {
        Section {
            if caps.archive, let pal {
                terminalRow(pal)
                if confirmEnd {
                    ConfirmPanel(title: Copy.spaced(String(localized: "归档「\(pal.displayName)」？")),
                                 text: String(localized: "它会停下，之后还能在已归档里拿回来。"),
                                 action: String(localized: "归档"), working: working == "end", glass: false,
                                 cancel: { confirmEnd = false }, confirm: { archive(pal.id) })
                } else {
                    Button("归档这个 agent", role: .destructive) { confirmEnd = true }
                        .frame(maxWidth: .infinity)
                        .disabled(!online)
                        .accessibilityIdentifier("detail-end")
                }
            } else if agent == nil {
                Button(String(localized: "让\(store.assistantName)停下"), role: .destructive) { confirmStop = true }
                    .frame(maxWidth: .infinity)
                    .disabled(!online || !store.assistantWorking || working == "stop")
                    .accessibilityIdentifier("detail-stop")
                    .confirmationDialog("让助理停下手上的事？", isPresented: $confirmStop, titleVisibility: .visible) {
                        Button("停下", role: .destructive) { stopAssistant() }
                        Button("再想想", role: .cancel) {}
                    } message: {
                        Text("正在办的事会中断。之后你再说话，它照常工作。")
                    }
            }
        }
    }

    // MARK: actions

    private func load() async {
        guard online else { return }
        guard let agent else {
            if store.modelInfo == nil { try? await store.loadModels() }
            return
        }
        do {
            palDetail = try await store.palDetail(id: agent)
            failure = nil
        } catch {
            if palDetail == nil { failure = Copy.error(error) }
        }
    }

    private func countMemory() async {
        guard online else { return }
        memoryCount = (try? await store.memoryFiles(agent: agent))?.filter { !$0.missing }.count
    }

    private func run(_ key: String, _ op: @escaping () async throws -> Void) {
        working = key
        failure = nil
        Task {
            defer { working = nil }
            do { try await op() } catch { failure = Copy.error(error) }
        }
    }

    private func beginRename(_ pal: Pal) {
        newName = pal.displayName
        editing = true
    }

    private func rename(_ id: String) async {
        let name = newName
        editing = false
        do { _ = try await store.renamePal(id: id, name: name) } catch { failure = String(localized: "没改成：\(Copy.error(error))") }
    }

    /// The one setter (the assistant's model.set or an agent's pals.setModel).
    private func setModel(_ m: String??, _ e: String??) {
        run("model") {
            try await store.setAgentModel(agent, model: m, effort: e)
            if let agent { palDetail = try await store.palDetail(id: agent) }
        }
    }

    /// Its permission mode; the one it's in already (one not offered, say) does nothing.
    private func setMode(_ mode: String, from current: String) {
        guard mode != current, let agent else { return }
        run("mode") {
            try await store.setSessionMode(id: agent, mode: mode)
            palDetail = try await store.palDetail(id: agent)
        }
    }

    private func compact() {
        guard let agent else { return }
        run("compact") {
            try await store.compactSession(id: agent)
            palDetail = try? await store.palDetail(id: agent)
        }
    }

    private func stop(_ t: AgentTask, in agent: String) {
        run("stop") {
            try await store.stopTask(id: agent, taskId: t.id)
            palDetail = try? await store.palDetail(id: agent)
        }
    }

    private func move(_ id: String, to workspaceID: String?) {
        run("move") { try await store.moveSession(id, to: workspaceID) }
    }

    private func archive(_ id: String) {
        run("end") {
            try await store.endSession(id: id)
            model.setDetail(false, tile: tileDetail)
            // On its own page it is gone; in a tile the workspace carries on.
            if tileDetail == nil { model.showList() }
        }
    }

    private func stopAssistant() {
        run("stop") {
            do { try await store.stop() } catch { throw FriendlyFailure(message: String(localized: "没成功：\(Friendly.message(error))")) }
        }
    }

    private var languageBinding: Binding<String> {
        Binding(get: { store.settings?.language ?? "" }, set: { lang in
            run("language") {
                do { try await store.updateSettings(patch: ["language": .string(lang)]) } catch {
                    throw FriendlyFailure(message: String(localized: "没改成：\(Copy.error(error))"))
                }
            }
        })
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { model.currentTheme }, set: { t in
            guard let id = model.activeHostID else { return }
            run("theme") {
                do { try await model.setTheme(t, for: id) } catch {
                    throw FriendlyFailure(message: String(localized: "颜色没改成：\(Copy.error(error))"))
                }
            }
        })
    }
}

/// An error whose words are already the owner's.
private struct FriendlyFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - the one model picker

/// 模型 and 思考深度, a menu each, for the assistant and an agent alike.
/// With `defaultChoice` the first model is the default (picking it sends
/// none) and 思考深度 has a 默认 row.
struct ModelPickers: View {
    let detail: AgentDetail
    var disabled = false
    /// `.some(nil)`: back to the default.
    let set: (_ model: String??, _ effort: String??) -> Void

    var body: some View {
        let caps = detail.capabilities
        let selected = detail.selectedModel
        Picker("模型", selection: Binding(get: { selected }, set: { m in
            guard m != selected else { return }
            set(caps.defaultChoice && m == detail.models.first?.id ? .some(nil) : .some(m), .none)
        })) {
            if !detail.models.contains(where: { $0.id == selected }) {
                Text(ModelName.short(detail.runningModel)).tag(selected)
            }
            ForEach(detail.models) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .detailNeutral()
        .disabled(disabled || detail.models.isEmpty)
        .accessibilityIdentifier("detail-model")
        if !detail.efforts.isEmpty {
            let current = detail.effort ?? ""
            Picker("思考深度", selection: Binding(get: { current }, set: { e in
                guard e != current else { return }
                set(.none, .some(e.isEmpty ? nil : e))
            })) {
                // 默认 (the assistant), or the one it is on when that's none of these
                if caps.defaultChoice || current.isEmpty { Text(detail.harness.effortLabel(nil)).tag("") }
                if !current.isEmpty, !detail.efforts.contains(current) { Text(detail.harness.effortLabel(current)).tag(current) }
                ForEach(detail.efforts, id: \.self) { Text(detail.harness.effortLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .detailNeutral()
            .disabled(disabled)
            .accessibilityIdentifier("detail-effort")
        }
    }
}

// MARK: - tasks

/// A subagent, a background command or one of the assistant's tasks: what it
/// is, since or until when, its latest line. The assistant's open their page.
struct AgentTaskRow: View {
    let task: AgentTask

    var body: some View {
        if task.kind == .task {
            NavigationLink { TaskDetailView(taskID: task.id) } label: { content }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(task.needsYou ? StatusDot.color(.waiting) : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? String(localized: "一件事") : task.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(kindWord)
                    if let end = task.endedAt, end > 0 {
                        Text(verbatim: "·")
                        Text(Copy.relative(end))
                    } else if task.startedAt > 0 {
                        Text(verbatim: "·")
                        Text(task.startedAt.msDate, style: .relative)
                    }
                    if let ending = task.ending, ending != .done {
                        Text(verbatim: "·")
                        Text(ending == .failed ? String(localized: "没成") : String(localized: "停了"))
                    } else if task.needsYou {
                        Text(verbatim: "·")
                        Text("需要你").foregroundStyle(StatusDot.color(.waiting))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let s = task.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    private var symbol: String {
        switch task.kind {
        case .subagent: "person.2"
        case .background: "terminal"
        case .task: task.ending == nil ? "circle.dotted" : (task.ending == .done ? "checkmark.circle" : "xmark.circle")
        }
    }

    private var kindWord: String {
        switch task.kind {
        case .subagent: String(localized: "子 agent")
        case .background: String(localized: "后台任务")
        case .task: task.ending == nil ? String(localized: "在做") : (task.ending == .done ? String(localized: "完成") : String(localized: "没做完"))
        }
    }
}

/// 全部记录: the assistant's by day (its own rows), an agent's newest first.
private struct HistoryPage: View {
    let agent: String?
    let tasks: [AgentTask]

    var body: some View {
        List {
            if agent == nil {
                HistorySection()
            } else {
                ForEach(tasks) { AgentTaskRow(task: $0) }
            }
        }
        .navigationTitle("记录")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(InSidebarColumn())
    }
}

/// 记忆: the assistant's, or an agent's (its folder's CLAUDE.md and project memory).
struct MemoryPage: View {
    let agent: String?

    var body: some View {
        List { MemorySection(agent: agent) }
            .navigationTitle("记忆")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(InSidebarColumn())
    }
}
