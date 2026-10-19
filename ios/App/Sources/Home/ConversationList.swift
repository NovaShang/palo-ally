import PaloAllyKit
import SwiftUI

/// The list (workbench-prd §4): Palo on top, big, with what it did last or
/// how many sessions wait on the owner; 工作区, each opening to its sessions
/// ("N 等你" on the row), with a ＋; 会话, the ordinary ones by latest
/// activity, ending in 以前的 N; Allies, with 添加; and, quietly, 电脑与设备.
/// At the foot: ＋ (新建会话, 新建工作区, 从终端搬进来…) and 设置. Every row's
/// dot is the one StatusDot. With several computers paired, the assistant's
/// name on the first row switches between them.
/// Phones: one step back from a conversation, like Messages; iPads and the
/// Mac: the sidebar.
struct ConversationList: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// 重命名 asked from a session's row (pals-prd §13).
    @State private var renaming: Pal?
    /// 重命名 asked from a workspace's row.
    @State private var renamingWorkspace: Workspace?
    @State private var workspaceName = ""
    /// 结束 asked, and 删除工作区.
    @State private var ending: Pal?
    @State private var deleting: Workspace?
    /// The workspaces opened in the list.
    @State private var expanded: Set<String> = []
    @State private var showNewSession = false
    @State private var newWorkspace: [String]?
    @State private var showAdopt = false

    var body: some View {
        @Bindable var model = model
        let tree = store.sidebarTree
        List(selection: $model.selection) {
            PaloItem(waitingSessions: tree.waitingCount)
                .tag(AppModel.Conversation.palo)
                .accessibilityIdentifier("row-palo")

            if store.palsSupported == true {
                if !tree.workspaces.isEmpty {
                    Section {
                        ForEach(tree.workspaces) { node in
                            WorkspaceRow(node: node, expanded: isExpanded(node)) { toggle(node) }
                                .tag(AppModel.Conversation.workspace(node.id))
                                .accessibilityIdentifier("row-workspace-\(node.id)")
                                .contextMenu { workspaceMenu(node.workspace) }
                            if isExpanded(node) {
                                ForEach(node.members) { pal in
                                    PalListRow(pal: pal, inset: true)
                                        .tag(AppModel.Conversation.pal(pal.id))
                                        .accessibilityIdentifier("row-pal-\(pal.id)")
                                        .contextMenu { sessionMenu(pal) }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("工作区").textCase(nil)
                            Spacer()
                            Button {
                                newWorkspace = []
                            } label: {
                                Image(systemName: "plus").font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                            .disabled(!store.connection.isOnline)
                            .accessibilityLabel("新建工作区")
                            .accessibilityIdentifier("workspace-add")
                        }
                    }
                }

                Section {
                    ForEach(tree.sessions) { pal in
                        PalListRow(pal: pal)
                            .tag(AppModel.Conversation.pal(pal.id))
                            .accessibilityIdentifier("row-pal-\(pal.id)")
                            .contextMenu { sessionMenu(pal) }
                    }
                    let earlier = tree.earlierCount(loaded: store.earlierItems)
                    if earlier > 0 || store.earlierItems != nil && store.earlierSupported != false {
                        EarlierRow(count: earlier)
                            .tag(AppModel.Conversation.earlier)
                            .accessibilityIdentifier("row-earlier")
                    }
                } header: {
                    Text("会话").textCase(nil)
                } footer: {
                    if store.pals.isEmpty {
                        Text("点左下角的 ＋ 新建一个会话，或者让 Palo 帮你开。")
                    }
                }
            }

            if store.alliesSupported != false {
                Section {
                    ForEach(store.allies) { ally in
                        AllyListRow(ally: ally)
                            .tag(AppModel.Conversation.ally(ally.id))
                            .accessibilityIdentifier("row-ally-\(ally.id)")
                    }
                    Button {
                        model.showAllyInvite = true
                    } label: {
                        // Neutral: the theme color is for 发送.
                        Label {
                            Text("添加").foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: "plus").foregroundStyle(Color.primary)
                        }
                    }
                    .tint(.primary)
                    .disabled(!store.connection.isOnline)
                } header: {
                    Text("Allies").textCase(nil)
                } footer: {
                    if store.allies.isEmpty {
                        Text("当面扫个码，你的助理就能和对方的助理互相传话、约时间。")
                    }
                }
            }

            // The computers and the devices paired with them: quiet, last.
            Section {
                DevicesListRow()
                    .tag(AppModel.Conversation.devices)
                    .accessibilityIdentifier("row-devices")
            }
        }
        // The Mac's sidebar has no title of its own; phones and iPads name the app.
        .navigationTitle(Platform.barInWindowToolbar ? "" : "PaloAlly")
        .toolbar(Platform.barInWindowToolbar ? .hidden : .automatic, for: .navigationBar)
        .modifier(MacSidebarToggle())
        // The foot: the Mac app is behind the computer's (a quiet capsule), then ＋ and 设置.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                MacUpdateHint()
                SidebarFooter(newSession: { showNewSession = true }, newWorkspace: { newWorkspace = [] },
                              adopt: { showAdopt = true })
            }
        }
        .palRename($renaming)
        .alert("重命名工作区", isPresented: Binding(get: { renamingWorkspace != nil }, set: { if !$0 { renamingWorkspace = nil } })) {
            TextField("名字", text: $workspaceName)
            Button("取消", role: .cancel) {}
            Button("好") {
                if let w = renamingWorkspace { Task { _ = try? await store.updateWorkspace(id: w.id, name: workspaceName) } }
            }
        }
        .confirmationDialog(Copy.spaced(String(localized: "结束「\(ending?.displayName ?? "")」？")), isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            titleVisibility: .visible) {
            Button("结束会话", role: .destructive) {
                if let p = ending { Task { await end(p) } }
            }
        } message: {
            Text("它会停下，进到「以前的」里，之后还能接着聊。")
        }
        .confirmationDialog(Copy.spaced(String(localized: "删除工作区「\(deleting?.title(pals: store.pals) ?? "")」？")),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除工作区", role: .destructive) {
                if let w = deleting { Task { try? await store.deleteWorkspace(id: w.id) } }
            }
        } message: {
            Text("里面的会话不会结束，变回普通会话。")
        }
        .sheet(isPresented: $showNewSession) { NewSessionSheet().environment(model).environment(store) }
        .sheet(isPresented: $showAdopt) { AdoptFlowSheet().environment(model).environment(store) }
        .sheet(isPresented: Binding(get: { newWorkspace != nil }, set: { if !$0 { newWorkspace = nil } })) {
            NewWorkspaceSheet(preselected: newWorkspace ?? []).environment(model).environment(store)
        }
        // 以前的 N: read on opening, and again when the sessions put away change.
        .task(id: "\(store.connection.isOnline)-\(tree.foldedCount)") {
            guard store.connection.isOnline, store.palsSupported == true else { return }
            try? await store.refreshEarlier()
        }
        // The workspace holding the session picked is opened.
        .onChange(of: model.selection, initial: true) { _, c in
            guard case .pal(let id)? = c, let ws = store.pal(id: id)?.workspaceId else { return }
            expanded.insert(ws)
        }
        .animation(.snappy, value: store.pals)
        .animation(.snappy, value: store.workspaces)
        .animation(.snappy, value: expanded)
    }

    // MARK: workspaces

    private func isExpanded(_ node: SidebarTree.WorkspaceNode) -> Bool { expanded.contains(node.id) }

    private func toggle(_ node: SidebarTree.WorkspaceNode) {
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    // MARK: menus

    @ViewBuilder private func sessionMenu(_ pal: Pal) -> some View {
        Button("重命名", systemImage: "pencil") { renaming = pal }
            .disabled(!store.connection.isOnline)
        if store.workspacesSupported == true {
            Menu("移到工作区", systemImage: "square.grid.2x2") {
                ForEach(store.workspaces.filter { $0.id != pal.workspaceId }) { w in
                    Button(w.title(pals: store.pals)) { Task { try? await store.moveSession(pal.id, to: w.id) } }
                }
                Button("新建工作区…") { newWorkspace = [pal.id] }
            }
            .disabled(!store.connection.isOnline)
            if pal.workspaceId != nil {
                Button("移出工作区", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { try? await store.moveSession(pal.id, to: nil) }
                }
                .disabled(!store.connection.isOnline)
            }
        }
        Divider()
        Button("结束会话", systemImage: "stop.circle", role: .destructive) { ending = pal }
            .disabled(!store.connection.isOnline)
    }

    @ViewBuilder private func workspaceMenu(_ w: Workspace) -> some View {
        Button("重命名", systemImage: "pencil") {
            workspaceName = w.name
            renamingWorkspace = w
        }
        .disabled(!store.connection.isOnline)
        Button("删除工作区", systemImage: "trash", role: .destructive) { deleting = w }
            .disabled(!store.connection.isOnline)
    }

    private func end(_ p: Pal) async {
        _ = try? await store.endSession(id: p.id)
        // Its page has nothing to show now.
        if model.selection == .pal(p.id) { model.showList() }
    }
}

/// The Mac: the window toolbar has the system sidebar toggle (MacToolbar);
/// the column doesn't add a second one.
private struct MacSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

// MARK: - rows

/// How many things wait on the owner in a conversation: an orange count on
/// the row's right (orange is what 「等你」 looks like everywhere in the app).
struct WaitingBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 22)
                .background(.orange, in: .capsule)
                .accessibilityLabel("\(count) 件等你")
        }
    }
}

/// Palo: the orb and the name, big; under it what it did last, or how many
/// sessions wait on the owner; what waits on the owner in its own
/// conversation as the count.
private struct PaloItem: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Sessions (anywhere) waiting on the owner.
    let waitingSessions: Int

    var body: some View {
        let line = store.agentStatusLine
        HStack(spacing: 14) {
            AssistantAvatar(theme: model.currentTheme, hostID: model.activeHostID, bleed: 1.3)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.hasSeveralHosts {
                        AssistantSwitcher(name: name)
                    } else {
                        Text(name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let ts = lastMessage?.ts, ts > 0 {
                        Text(Copy.relative(ts))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(secondLine(line))
                        .font(.subheadline)
                        .foregroundStyle(line.kind == .offline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    WaitingBadge(count: waiting)
                }
            }
        }
        .padding(.vertical, 8)
        // Several computers: the switcher in it is a control of its own.
        .accessibilityElement(children: model.hasSeveralHosts ? .contain : .combine)
    }

    private var name: String { store.assistantName.isEmpty ? "Palo" : store.assistantName }

    private var lastMessage: ChatMessage? {
        store.messages.last { $0.seq > 0 && $0.kind != .approval }
    }

    /// Working or offline: the state, as the orb's caption says it.
    /// Sessions waiting on the owner: how many. Otherwise what it did last.
    private func secondLine(_ line: AgentStatusLine) -> String {
        if line.kind == .working || line.kind == .offline { return line.text }
        if waitingSessions > 0 { return String(localized: "\(waitingSessions) 个会话在等你") }
        guard let m = lastMessage else {
            return line.kind == .needsYou ? String(localized: "等你") : line.text
        }
        let text = m.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return line.text }
        return m.role == .user ? String(localized: "你：\(text)") : text
    }

    /// Cards, drafts and proposals waiting in its conversation, and tasks
    /// that need the owner.
    private var waiting: Int {
        store.pendingApprovals.count + store.pendingQuestions.count + store.pendingAllyDrafts.count
            + store.pendingProposalCount + store.tasks.filter { $0.status == .needsInput }.count
    }
}

/// A workspace: a chevron that opens it, its icon and name; on the right how
/// many of its sessions wait on the owner, else how many it holds.
private struct WorkspaceRow: View {
    let node: SidebarTree.WorkspaceNode
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 22, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(toggleLabel)
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(node.title.isEmpty ? String(localized: "工作区") : node.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if node.waiting > 0 {
                Text("\(node.waiting) 等你")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text("\(node.members.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: toggleLabel, toggle)
    }

    private var toggleLabel: String { expanded ? String(localized: "收起") : String(localized: "展开") }
}

/// A session: its dot and name; on the right what waits on the owner, else
/// when it was last busy. Phones add its last words under the name.
private struct PalListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let pal: Pal
    /// Listed under its workspace.
    var inset = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(pal, size: 9)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(pal.displayName)
                    .font(.body)
                    .lineLimit(1)
                if model.layout == .phone {
                    Text(Copy.palLine(pal))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            let waiting = store.palPendingCount(pal.id)
            if waiting > 0 {
                WaitingBadge(count: waiting)
            } else if let at = pal.updatedAt, at > 0 {
                Text(Copy.relative(at))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, model.layout == .phone ? 3 : 1)
        .padding(.leading, inset ? 24 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityValue(StatusDot.label(pal.dot))
    }
}

/// 以前的 N: the sessions that ended or were put away; quiet, neutral.
private struct EarlierRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("以前的")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The sidebar's foot: ＋ with its menu on the left, 设置 on the right.
/// Neutral glass; the theme color isn't used.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let newSession: () -> Void
    let newWorkspace: () -> Void
    let adopt: () -> Void

    var body: some View {
        HStack {
            Menu {
                Button("新建会话", systemImage: "square.and.pencil", action: newSession)
                Button("新建工作区", systemImage: "square.grid.2x2", action: newWorkspace)
                if store.palsSupported == true {
                    Divider()
                    Button("从终端搬进来…", systemImage: "terminal", action: adopt)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .menuIndicator(.hidden)
            .disabled(!store.connection.isOnline)
            .accessibilityLabel("新建")
            .accessibilityIdentifier("sidebar-add")
            Spacer()
            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .accessibilityLabel("设置")
            .accessibilityIdentifier("sidebar-settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Several computers paired: the assistant's name with a ⌄, a system menu
/// of every assistant (the current one ticked, a dot on one with something
/// new or waiting) and 电脑与设备… (docs/devices-prd.md §2).
private struct AssistantSwitcher: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(model.hostIDs, id: \.self) { id in
                    Button {
                        withAnimation(.snappy) { model.switchTo(id) }
                    } label: {
                        let label = model.assistantLabel(id)
                        let waiting = model.pendingCount(id)
                        let unread = model.unreadCount(id)
                        if id == model.activeHostID {
                            Label(label, systemImage: "checkmark")
                        } else if waiting > 0 || unread > 0 {
                            // A small dot, and what it is under the name.
                            Text(label)
                            Text(waiting > 0 ? String(localized: "\(waiting) 件等你") : String(localized: "有新消息"))
                            Image(systemName: "circlebadge.fill")
                        } else {
                            Text(label)
                        }
                    }
                    .accessibilityIdentifier("switch-\(id)")
                }
                Divider()
                Button("电脑与设备…", systemImage: "desktopcomputer") { model.open(.devices) }
            } label: {
                if Platform.isMac {
                    // The Mac draws a menu's label as a button's title, and
                    // its own ⌄ after it (menuIndicator).
                    Text(name).font(.body.weight(.semibold))
                } else {
                    HStack(spacing: 3) {
                        Text(name).font(.body.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .contentShape(.rect)
                }
            }
            .menuIndicator(Platform.isMac ? .visible : .hidden)
            .buttonStyle(.borderless)
            .tint(.primary)
            .fixedSize()
            .accessibilityIdentifier("assistant-switcher")
            .accessibilityLabel("\(name)，切换助理")
            // Something new or waiting on another assistant.
            if model.othersNeedAttention {
                Circle().fill(.orange).frame(width: 6, height: 6).accessibilityHidden(true)
            }
        }
    }
}

/// 电脑与设备: the last row, quiet (secondary), like 最近的对话.
private struct DevicesListRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 40)
                .accessibilityHidden(true)
            Text("电脑与设备")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An Ally, with their drafts waiting for 发送.
private struct AllyListRow: View {
    @Environment(AppStore.self) private var store
    let ally: AllyInfo

    var body: some View {
        HStack(spacing: 8) {
            AllyRow(ally: ally, assistant: store.assistantName)
            WaitingBadge(count: store.pendingAllyDrafts.filter { $0.allyId == ally.id }.count)
        }
    }
}
