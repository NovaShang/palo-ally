import PaloAllyKit
import SwiftUI

/// The list (workbench-prd §4): Palo on top, big, with what it did last or
/// how many sessions wait on the owner; 工作区, each opening to its sessions
/// ("N 等你" on the row), with a ＋; 会话, the ordinary ones by latest
/// activity; Allies, with 添加; and, quietly, 电脑与设备. Workspaces and
/// sessions are in the owner's own order, which a drag changes (kept on the
/// computer, the same on every device): reorder, drop one session on another
/// to make a workspace, drag in and out of a workspace (`SidebarDragDrop`).
/// At the foot: ＋ (新建会话, 从历史记录继续…, 新建工作区) and 设置. Every row's
/// dot is the one StatusDot. With several computers paired, the assistant's
/// name on the first row switches between them.
/// Phones: one step back from a conversation, like Messages; iPads and the
/// Mac: the sidebar.
struct ConversationList: View {
    @Environment(WindowModel.self) private var model
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
    /// 更早的会话 opened.
    @AppStorage("sidebarEarlierOpen") private var earlierOpen = false
    /// What a drop failed with.
    @State private var dropFailure: String?

    var body: some View {
        @Bindable var model = model
        let tree = store.sidebarTree
        let order = store.sessionOrder
        let drop = { (move: SidebarDrop.Move) in run(move) }
        // Only with a host that has workspaces (and a list to drag in).
        let dnd = store.workspacesSupported == true
        List(selection: $model.selection) {
            PaloItem(waitingSessions: tree.waitingCount)
                .tag(WindowModel.Conversation.palo)
                .accessibilityIdentifier("row-palo")
                .modifier(OpenInNewWindow(conversation: .palo))
                .contextMenu { OpenInNewWindowButton(conversation: .palo) }

            if store.palsSupported == true {
                if !tree.workspaces.isEmpty {
                    Section {
                        ForEach(tree.workspaces) { node in
                            WorkspaceRow(node: node, expanded: isExpanded(node)) { toggle(node) }
                                .tag(WindowModel.Conversation.workspace(node.id))
                                .accessibilityIdentifier("row-workspace-\(node.id)")
                                .contextMenu { workspaceMenu(node.workspace) }
                                .sidebarRowDrag(dnd, drags: .workspace(node.id), conversation: .workspace(node.id),
                                                target: .workspace(node.id), tree: tree, sessionOrder: order, perform: drop)
                            if isExpanded(node) {
                                ForEach(node.members) { pal in
                                    PalListRow(pal: pal, inset: true)
                                        .tag(WindowModel.Conversation.pal(pal.id))
                                        .accessibilityIdentifier("row-pal-\(pal.id)")
                                        .contextMenu { sessionMenu(pal) }
                                        .sidebarRowDrag(dnd, drags: .session(pal.id), conversation: .pal(pal.id),
                                                        target: .member(pal.id, workspace: node.id), tree: tree, sessionOrder: order,
                                                        perform: drop)
                                }
                            }
                        }
                    } header: {
                        Text("工作区").textCase(nil)
                    }
                }

                Section {
                    ForEach(tree.sessions) { pal in
                        PalListRow(pal: pal)
                            .tag(WindowModel.Conversation.pal(pal.id))
                            .accessibilityIdentifier("row-pal-\(pal.id)")
                            .contextMenu { sessionMenu(pal) }
                            .sidebarRowDrag(dnd, drags: .session(pal.id), conversation: .pal(pal.id), target: .session(pal.id),
                                            tree: tree, sessionOrder: order, perform: drop)
                    }
                    // Put away for lack of use: one quiet row, opened in place,
                    // so they are still there to see (and the rest of the history a tap on).
                    if !tree.folded.isEmpty {
                        EarlierRow(count: tree.folded.count, expanded: earlierOpen) { earlierOpen.toggle() }
                            .accessibilityIdentifier("row-earlier")
                        if earlierOpen {
                            ForEach(tree.folded) { pal in
                                PalListRow(pal: pal, inset: true)
                                    .tag(WindowModel.Conversation.pal(pal.id))
                                    .accessibilityIdentifier("row-pal-\(pal.id)")
                                    .contextMenu { sessionMenu(pal) }
                            }
                            Button { model.historyPickerPresented = true } label: {
                                Text("全部历史记录…")
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 22)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .tint(.primary)
                            .accessibilityIdentifier("row-earlier-history")
                        }
                    }
                } header: {
                    // Also where a session dragged out of a workspace can land: the top.
                    Text("会话").textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sidebarRowDrag(dnd, drags: nil, conversation: nil, target: .sessionsTop, tree: tree, sessionOrder: order,
                                        perform: drop)
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
                            .tag(WindowModel.Conversation.ally(ally.id))
                            .accessibilityIdentifier("row-ally-\(ally.id)")
                    }
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
                    .tag(WindowModel.Conversation.devices)
                    .accessibilityIdentifier("row-devices")
            }
        }
        // The Mac's sidebar has no title of its own; phones and iPads name the app.
        .navigationTitle(Platform.barInWindowToolbar ? "" : "PaloAlly")
        .toolbar(Platform.barInWindowToolbar ? .hidden : .automatic, for: .navigationBar)
        .modifier(MacSidebarToggle())
        .modifier(MacSidebarLook())
        // The foot: the Mac app is behind the computer's (a quiet capsule), then ＋ and 设置.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                MacUpdateHint()
                SidebarFooter(newSession: { model.newSession = true }, newWorkspace: { model.newWorkspace = [] },
                              history: { model.historyPickerPresented = true })
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
            Text("它会停下，之后还能从历史记录里接着聊。")
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
        .alert(dropFailure ?? "", isPresented: Binding(get: { dropFailure != nil }, set: { if !$0 { dropFailure = nil } })) {
            Button("好", role: .cancel) { dropFailure = nil }
        }
        #if DEBUG
        .task { await demoDrops(tree: { store.sidebarTree }) }
        #endif
        // The workspace holding the session picked is opened.
        .onChange(of: model.selection, initial: true) { _, c in
            guard case .pal(let id)? = c, let ws = store.pal(id: id)?.workspaceId else { return }
            expanded.insert(ws)
        }
        .animation(.snappy, value: store.pals)
        .animation(.snappy, value: store.workspaces)
        .animation(.snappy, value: expanded)
    }

    // MARK: dropping

    /// A drag let go: shown at once by the store, kept on the computer. One
    /// session onto another: 新建工作区 with both, for the owner to name.
    private func run(_ move: SidebarDrop.Move) {
        debugLog("[sidebar-drop] \(move)")
        if case .group(let target, let dragged) = move {
            model.newWorkspace = [target, dragged]
            return
        }
        Task {
            do {
                switch move {
                case .reorderSessions(let ids): try await store.reorderSessions(ids)
                case .reorderWorkspaces(let ids): try await store.reorderWorkspaces(ids)
                case .reorderMembers(let ws, let ids): try await store.reorderMembers(workspaceId: ws, ids)
                case .moveSession(let id, let ws, let index):
                    if let ws { expanded.insert(ws) }
                    try await store.moveSession(id, to: ws, index: index)
                case .group: break
                }
            } catch {
                dropFailure = Copy.error(error)
            }
        }
    }

    #if DEBUG
    /// `-demoDrops "session:pal-notes>session:pal-photos:after,..."`: drops
    /// through the same plan and `run` a real drop takes (targets:
    /// `session:<id>`, `member:<id>@<workspace>`, `workspace:<id>`, `top`;
    /// zones: before, onto, after), two seconds apart, logging the list after
    /// each. The first window runs them.
    private func demoDrops(tree: () -> SidebarTree) async {
        guard let steps = UserDefaults.standard.string(forKey: "demoDrops") else { return }
        try? await Task.sleep(for: .seconds(5))
        guard model.app.windows.first === model else { return }
        for step in steps.split(separator: ",").map(String.init) {
            let parts = step.split(separator: ">", maxSplits: 1).map(String.init)
            let rest = parts.count == 2 ? parts[1].split(separator: ":").map(String.init) : []
            guard parts.count == 2, let item = SidebarDrop.Item(token: parts[0]), !rest.isEmpty else {
                debugLog("[sidebar-drop] bad step \(step)"); continue
            }
            let zone: SidebarDrop.Zone = switch rest.last { case "before": .before; case "after": .after; default: .onto }
            let target: SidebarDrop.Target? = switch rest[0] {
            case "top": .sessionsTop
            case "session" where rest.count >= 2: .session(rest[1])
            case "workspace" where rest.count >= 2: .workspace(rest[1])
            case "member" where rest.count >= 2:
                rest[1].split(separator: "@").count == 2
                    ? .member(String(rest[1].split(separator: "@")[0]), workspace: String(rest[1].split(separator: "@")[1])) : nil
            default: nil
            }
            guard let target else { debugLog("[sidebar-drop] bad target in \(step)"); continue }
            if let move = SidebarDrop.plan(item, on: target, zone: zone, tree: tree(), sessionOrder: store.sessionOrder) {
                run(move)
            } else {
                debugLog("[sidebar-drop] \(step): nothing to do")
            }
            try? await Task.sleep(for: .seconds(2))
            let t = tree()
            debugLog("[sidebar-drop] after \(step): workspaces \(t.workspaces.map { "\($0.id)[\($0.members.map(\.id).joined(separator: " "))]" }.joined(separator: " ")) sessions \(t.sessions.map(\.id).joined(separator: " ")) newWorkspace \(model.newWorkspace.map { $0.joined(separator: " ") } ?? "-")")
        }
    }
    #endif

    // MARK: workspaces

    private func isExpanded(_ node: SidebarTree.WorkspaceNode) -> Bool { expanded.contains(node.id) }

    private func toggle(_ node: SidebarTree.WorkspaceNode) {
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    // MARK: menus

    @ViewBuilder private func sessionMenu(_ pal: Pal) -> some View {
        OpenInNewWindowButton(conversation: .pal(pal.id))
        Button("重命名", systemImage: "pencil") { renaming = pal }
            .disabled(!store.connection.isOnline)
        if store.workspacesSupported == true {
            Menu("移到工作区", systemImage: "square.grid.2x2") {
                ForEach(store.workspaces.filter { $0.id != pal.workspaceId }) { w in
                    Button(w.title(pals: store.pals)) { Task { try? await store.moveSession(pal.id, to: w.id) } }
                }
                Button("新建工作区…") { model.newWorkspace = [pal.id] }
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
        OpenInNewWindowButton(conversation: .workspace(w.id))
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

/// The Mac: a Mac sidebar's own rows, 28 pt like Finder's, not a touch
/// screen's 44; and a neutral gray selection, as Finder's when the sidebar
/// isn't focused, so the Palo orb and the status dots are what stand out.
/// The rows keep their own text colors on it (sidebarRowText).
private struct MacSidebarLook: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.isMac {
            content
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 28)
                .tint(Color(uiColor: .systemGray4))
        } else {
            content
        }
    }
}

extension View {
    /// The Mac: a sidebar row's text stays the label color when selected
    /// (the selection would draw it in its tint, gray on gray).
    @ViewBuilder func sidebarRowText() -> some View {
        if Platform.isMac { foregroundStyle(Color.primary) } else { self }
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
                .background(StatusDot.color(.waiting), in: .capsule)
                .accessibilityLabel("\(count) 件等你")
        }
    }
}

/// The big orb is the orb's resting place while the sidebar is docked (the
/// floating copy leaves it to the capsule).
private struct OrbHomeIfDocked: ViewModifier {
    @Environment(\.inFloatingSidebar) private var floating
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        // Phones: never. The list stays alive under Palo's page, so it would
        // keep claiming the place off screen, and the orb would fly in from
        // there, or from nowhere; Palo's page drops it from its own bar.
        if floating || model.layout == .phone { content } else { content.paloOrbHome() }
    }
}

/// Palo: the orb and the name, big; under it what it did last, or how many
/// sessions wait on the owner; what waits on the owner in its own
/// conversation as the count.
private struct PaloItem: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Sessions (anywhere) waiting on the owner.
    let waitingSessions: Int

    var body: some View {
        let line = store.agentStatusLine
        SidebarRowLayout {
            AssistantAvatar(theme: model.currentTheme, hostID: model.activeHostID, bleed: 1.3)
                .frame(width: 30, height: 30)
                .modifier(OrbHomeIfDocked())
        } title: {
            if model.hasSeveralHosts {
                AssistantSwitcher(name: name)
            } else {
                Text(name)
            }
        } subtitle: {
            Text(secondLine(line))
                .foregroundStyle(line.kind == .offline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        } trailing: {
            // The count leads to what waits (the row still opens the conversation).
            WaitingBadge(count: waiting)
                .simultaneousGesture(TapGesture().onEnded { model.showWaiting(in: store, open: true) })
        }
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
        HStack(spacing: 2) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 20, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(toggleLabel)
            SidebarRowLayout {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } title: {
                Text(node.title.isEmpty ? String(localized: "工作区") : node.title)
            } subtitle: {
                Text("\(node.members.count) 个会话")
            } trailing: {
                if node.waiting > 0 { WaitingBadge(count: node.waiting) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: toggleLabel, toggle)
    }

    private var toggleLabel: String { expanded ? String(localized: "收起") : String(localized: "展开") }
}

/// 更早的会话 N: the sessions put away for lack of use, opened in place.
private struct EarlierRow: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 20, height: 28)
                Text("更早的会话")
                Spacer(minLength: 8)
                Text("\(count)").monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .accessibilityLabel(String(localized: "更早的会话，\(count) 个"))
        .accessibilityHint(expanded ? String(localized: "收起") : String(localized: "展开"))
    }
}

/// A session: its state glyph, its name and its last words under it; on the
/// right what waits on the owner. No time: the room goes to the two lines.
private struct PalListRow: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let pal: Pal
    /// Listed under its workspace.
    var inset = false

    var body: some View {
        SidebarRowLayout {
            // The state glyph of the session's indicator, alone (no arc, no label).
            SessionIndicator(pal, size: 28, glyphOnly: true)
        } title: {
            Text(pal.displayName)
        } subtitle: {
            Text(Copy.palLine(pal))
        } trailing: {
            WaitingBadge(count: store.palPendingCount(pal.id))
        }
        .padding(.leading, inset ? 24 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityValue(StatusDot.label(pal.dot))
    }
}

/// Every row of the list (docs/workbench-design/mac-sidebar.html): a 28 pt
/// column for its picture, its name, a gray line under it, on the right
/// only what waits on the owner; one row height for all of them.
struct SidebarRowLayout<Icon: View, Title: View, Subtitle: View, Trailing: View>: View {
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing
    @Environment(WindowModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.body)
                    .lineLimit(1)
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, Self.verticalPadding(model))
        .sidebarRowText()
    }

    static func verticalPadding(_ model: WindowModel) -> CGFloat {
        model.layout == .phone ? 3 : (Platform.isMac ? 8 : 1)
    }
}

/// The sidebar's foot: ＋ with its menu on the left, 设置 on the right.
/// Neutral glass; the theme color isn't used.
private struct SidebarFooter: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let newSession: () -> Void
    let newWorkspace: () -> Void
    let history: () -> Void

    var body: some View {
        HStack {
            Menu {
                Button("新建会话", systemImage: "square.and.pencil", action: newSession)
                if store.palsSupported == true {
                    Button("从历史记录继续…", systemImage: "clock.arrow.circlepath", action: history)
                        .accessibilityIdentifier("history-continue")
                }
                Button("新建工作区", systemImage: "square.grid.2x2", action: newWorkspace)
                if store.alliesSupported != false {
                    Button("添加 Ally…", systemImage: "person.badge.plus") { model.showAllyInvite = true }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .menuIndicator(.hidden)
            .modifier(FooterMenuStyle())
            .tint(.primary)
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
                    .contentShape(.circle)
            }
            .glassCircleButton()
            .tint(.primary)
            .accessibilityLabel("设置")
            .accessibilityIdentifier("sidebar-settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The footer's ＋ as a menu button. On the Mac a Menu with the glass button
/// style draws as a flat chip; the borderless menu with glass outside it is
/// round glass like 设置 (as the page strips' ⋯, MacStripMenu).
private struct FooterMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.isMac {
            content
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
    }
}

/// Several computers paired: the assistant's name with a ⌄, a system menu
/// of every assistant (the current one ticked, a dot on one with something
/// new or waiting) and 电脑与设备… (docs/devices-prd.md §2).
private struct AssistantSwitcher: View {
    @Environment(WindowModel.self) private var model
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
                Circle().fill(StatusDot.color(.waiting)).frame(width: 6, height: 6).accessibilityHidden(true)
            }
        }
    }
}

/// 电脑与设备: the last row, quiet (secondary), like 最近的对话.
private struct DevicesListRow: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        SidebarRowLayout {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        } title: {
            Text("电脑与设备")
        } subtitle: {
            Text(model.pairedHost?.hostLabel ?? "")
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
    }
}

/// An Ally, with their drafts waiting for 发送.
private struct AllyListRow: View {
    @Environment(AppStore.self) private var store
    let ally: AllyInfo

    var body: some View {
        SidebarRowLayout {
            AllyAvatar(ally: ally, size: 28)
        } title: {
            HStack(spacing: 6) {
                Text(ally.displayName)
                AllyKindTag(kind: ally.kind)
            }
        } subtitle: {
            Text(Copy.allyLastLine(ally, assistant: store.assistantName))
        } trailing: {
            WaitingBadge(count: store.pendingAllyDrafts.filter { $0.allyId == ally.id }.count)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Copy.allyPresence(ally))
    }
}
