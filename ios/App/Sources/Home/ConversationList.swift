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
/// dot is the one StatusDot.
///
/// Several computers paired (docs/workbench-design/multi-host-sidebar.html):
/// all of them at once, a section each under its name and an online dot,
/// folded or opened by a tap on the name (kept per computer; folded, what
/// waits there is counted beside it). A row of any computer opens in this
/// window, which takes that computer (its color, right pane, composer); no
/// switching step. The Mac lists its own computer first; otherwise the
/// owner's order (上移 / 下移 on a name), never by recency. One computer:
/// as before, no names.
/// Phones: one step back from a conversation, like Messages; iPads and the
/// Mac: the sidebar.
struct ConversationList: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Renames, 结束 and 删除 asked from a row, and on which computer.
    @State private var actions = SidebarActions()

    var body: some View {
        let several = model.hasSeveralHosts
        ScrollViewReader { proxy in
            List(selection: selection) {
                if several {
                    ForEach(model.app.sidebarHostIDs, id: \.self) { id in
                        if let s = model.stores[id] {
                            HostSidebarContent(hostID: id, several: true, actions: actions)
                                .environment(s)
                                .environment(\.sidebarHost, id)
                        }
                    }
                } else {
                    HostSidebarContent(hostID: model.activeHostID, several: false, actions: actions)
                }

                // The computers and the devices paired with them: quiet, last.
                Section {
                    DevicesListRow()
                        .tag(WindowModel.SidebarPick(host: model.activeHostID, conversation: .devices))
                        .accessibilityIdentifier("row-devices")
                }
            }
            // The list is made again with each computer the window takes
            // (MainScreen): the row just opened is brought back into view.
            .task {
                // A window that comes up on a computer folded only by default: its section opens.
                if model.hasSeveralHosts, let id = model.activeHostID, model.app.hostFoldUnset(id), model.app.isHostCollapsed(id) {
                    model.app.setHostCollapsed(id, false)
                }
                guard let reveal = model.sidebarReveal else { return }
                model.sidebarReveal = nil
                try? await Task.sleep(for: .milliseconds(50))
                proxy.scrollTo(reveal)
            }
        }
        // The Mac's sidebar has no title of its own; phones and iPads name the app.
        .navigationTitle(Platform.barInWindowToolbar ? "" : "Palo")
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
        // The dialogs a row asks for, on the computer of that row.
        .background {
            SidebarDialogs(actions: actions)
                .environment(actions.store ?? store)
        }
        // The workspace holding the session picked is opened.
        .onChange(of: model.selection, initial: true) { _, c in
            guard case .pal(let id)? = c, let ws = store.pal(id: id)?.workspaceId else { return }
            model.sidebarExpanded.insert(WindowModel.SidebarPick.expandKey(host: model.activeHostID, workspace: ws))
        }
        .animation(.snappy, value: store.pals)
        .animation(.snappy, value: store.workspaces)
        .animation(.snappy, value: model.sidebarExpanded)
        .animation(.snappy, value: model.app.collapsedHosts)
        .animation(.snappy, value: model.app.sidebarHostIDs)
    }

    /// The list's selection is the window's conversation on the window's
    /// computer; a row of another computer's opens it there (`open(_:on:)`).
    private var selection: Binding<WindowModel.SidebarPick?> {
        Binding(
            get: { model.selection.map { WindowModel.SidebarPick(host: model.activeHostID, conversation: $0) } },
            set: { pick in
                guard let pick else {
                    model.selection = nil
                    return
                }
                model.open(pick.conversation, on: pick.host)
            })
    }
}

/// What a row of the sidebar asked for, and on which computer's store.
@MainActor @Observable
final class SidebarActions {
    var store: AppStore?
    var host: String?
    /// 重命名 asked from a session's row (pals-prd §13).
    var renaming: Pal?
    /// 重命名 asked from a workspace's row.
    var renamingWorkspace: Workspace?
    var workspaceName = ""
    /// 结束 asked, and 删除工作区.
    var ending: Pal?
    var deleting: Workspace?
    /// What a drop failed with.
    var dropFailure: String?

    func on(_ store: AppStore, host: String?) {
        self.store = store
        self.host = host
    }
}

/// The alerts and confirmations for SidebarActions, on its computer's store.
private struct SidebarDialogs: View {
    @Bindable var actions: SidebarActions
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .palRename($actions.renaming)
            .alert("重命名工作区", isPresented: Binding(get: { actions.renamingWorkspace != nil },
                                                   set: { if !$0 { actions.renamingWorkspace = nil } })) {
                TextField("名字", text: $actions.workspaceName)
                Button("取消", role: .cancel) {}
                Button("好") {
                    if let w = actions.renamingWorkspace {
                        let name = actions.workspaceName
                        Task { _ = try? await store.updateWorkspace(id: w.id, name: name) }
                    }
                }
            }
            .confirmationDialog(Copy.spaced(String(localized: "结束「\(actions.ending?.displayName ?? "")」？")),
                                isPresented: Binding(get: { actions.ending != nil }, set: { if !$0 { actions.ending = nil } }),
                                titleVisibility: .visible) {
                Button("结束会话", role: .destructive) {
                    if let p = actions.ending { Task { await end(p) } }
                }
            } message: {
                Text("它会停下，之后还能从历史记录里接着聊。")
            }
            .confirmationDialog(Copy.spaced(String(localized: "删除工作区「\(actions.deleting?.title(pals: store.pals) ?? "")」？")),
                                isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                                titleVisibility: .visible) {
                Button("删除工作区", role: .destructive) {
                    if let w = actions.deleting { Task { try? await store.deleteWorkspace(id: w.id) } }
                }
            } message: {
                Text("里面的会话不会结束，变回普通会话。")
            }
            .alert(actions.dropFailure ?? "", isPresented: Binding(get: { actions.dropFailure != nil },
                                                                   set: { if !$0 { actions.dropFailure = nil } })) {
                Button("好", role: .cancel) { actions.dropFailure = nil }
            }
    }

    private func end(_ p: Pal) async {
        let host = actions.host ?? model.activeHostID
        _ = try? await store.endSession(id: p.id)
        // Its page has nothing to show now.
        if model.selection == .pal(p.id) && host == model.activeHostID { model.showList() }
    }
}

/// One computer's part of the list: with several computers its name over
/// it (`HostHeader`), and the rows only while its section is open; with one,
/// today's list as it was. Every row is tagged with its computer.
private struct HostSidebarContent: View {
    let hostID: String?
    /// Several computers listed: a header, folding, and dimmed rows while offline.
    let several: Bool
    let actions: SidebarActions
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    /// 更早的会话 opened (with several computers, per computer).
    @AppStorage private var earlierOpen: Bool

    init(hostID: String?, several: Bool, actions: SidebarActions) {
        self.hostID = hostID
        self.several = several
        self.actions = actions
        _earlierOpen = AppStorage(wrappedValue: false, several ? "sidebarEarlierOpen.\(hostID ?? "")" : "sidebarEarlierOpen")
    }

    private func pick(_ c: WindowModel.Conversation) -> WindowModel.SidebarPick {
        WindowModel.SidebarPick(host: hostID, conversation: c)
    }

    /// The row's identifier: as before with one computer, with its computer's id with several.
    private func rowID(_ base: String) -> String { several ? "\(base)@\(hostID ?? "")" : base }

    private var collapsed: Bool { several && hostID.map(model.app.isHostCollapsed) == true }
    private var dimmed: Bool { several && hostID.map(model.isOnline) != true }

    var body: some View {
        let tree = store.sidebarTree
        let order = store.sessionOrder
        let drop = { (move: SidebarDrop.Move) in run(move) }
        // Only with a host that has workspaces (and a list to drag in).
        let dnd = store.workspacesSupported == true
        if several, let hostID {
            Section {
                if !collapsed { paloRow(tree) }
            } header: {
                HostHeader(hostID: hostID, collapsed: collapsed)
            }
        } else {
            // One computer: the first row, as it always was.
            paloRow(tree)
        }

        if !collapsed {
            if store.palsSupported == true {
                if !tree.workspaces.isEmpty {
                    Section {
                        ForEach(tree.workspaces) { node in
                            WorkspaceRow(node: node, expanded: isExpanded(node)) { toggle(node) }
                                .modifier(HostRowDim(dimmed: dimmed))
                                .sidebarPick(pick(.workspace(node.id)))
                                .accessibilityIdentifier(rowID("row-workspace-\(node.id)"))
                                .contextMenu { workspaceMenu(node.workspace) }
                                .sidebarRowDrag(dnd, drags: .workspace(node.id), conversation: .workspace(node.id),
                                                target: .workspace(node.id), tree: tree, sessionOrder: order, perform: drop)
                            if isExpanded(node) {
                                ForEach(node.members) { pal in
                                    PalListRow(pal: pal, inset: true)
                                        .modifier(HostRowDim(dimmed: dimmed))
                                        .sidebarPick(pick(.pal(pal.id)))
                                        .accessibilityIdentifier(rowID("row-pal-\(pal.id)"))
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
                            .modifier(HostRowDim(dimmed: dimmed))
                            .sidebarPick(pick(.pal(pal.id)))
                            .accessibilityIdentifier(rowID("row-pal-\(pal.id)"))
                            .contextMenu { sessionMenu(pal) }
                            .sidebarRowDrag(dnd, drags: .session(pal.id), conversation: .pal(pal.id), target: .session(pal.id),
                                            tree: tree, sessionOrder: order, perform: drop)
                    }
                    // Put away for lack of use: one quiet row, opened in place,
                    // so they are still there to see (and the rest of the history a tap on).
                    if !tree.folded.isEmpty {
                        EarlierRow(count: tree.folded.count, expanded: earlierOpen) { earlierOpen.toggle() }
                            .accessibilityIdentifier(rowID("row-earlier"))
                        if earlierOpen {
                            ForEach(tree.folded) { pal in
                                PalListRow(pal: pal, inset: true)
                                    .modifier(HostRowDim(dimmed: dimmed))
                                    .sidebarPick(pick(.pal(pal.id)))
                                    .accessibilityIdentifier(rowID("row-pal-\(pal.id)"))
                                    .contextMenu { sessionMenu(pal) }
                            }
                            Button {
                                onThisHost()
                                model.historyPickerPresented = true
                            } label: {
                                Text("全部历史记录…")
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 22)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .tint(.primary)
                            .accessibilityIdentifier(rowID("row-earlier-history"))
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
                        Text("点左下角的 ＋ 新建一个会话，或者让助理帮你开。")
                    }
                }
            }

            // Several computers: a computer's Allies only when it has some (添加 is in ＋).
            if store.alliesSupported != false && !(several && store.allies.isEmpty) {
                Section {
                    ForEach(store.allies) { ally in
                        AllyListRow(ally: ally)
                            .modifier(HostRowDim(dimmed: dimmed))
                            .sidebarPick(pick(.ally(ally.id)))
                            .accessibilityIdentifier(rowID("row-ally-\(ally.id)"))
                    }
                } header: {
                    Text("好友").textCase(nil)
                } footer: {
                    if store.allies.isEmpty {
                        Text("当面扫个码，你的助理就能和对方的助理互相传话、约时间。")
                    }
                }
            }
        }
    }

    private func paloRow(_ tree: SidebarTree) -> some View {
        PaloItem(hostID: hostID, waitingSessions: tree.waitingCount)
            .modifier(HostRowDim(dimmed: dimmed))
            .sidebarPick(pick(.palo))
            .accessibilityIdentifier(rowID("row-palo"))
            .modifier(OpenInNewWindow(conversation: .palo))
            .contextMenu { OpenInNewWindowButton(conversation: .palo) }
            #if DEBUG
            .task { if !several { await demoDrops(tree: { store.sidebarTree }) } }
            #endif
    }

    /// Something that opens on the window's own computer (a sheet): the window takes this row's first.
    private func onThisHost() {
        if let hostID, hostID != model.activeHostID { model.switchTo(hostID, showAssistant: false) }
    }

    // MARK: dropping

    /// A drag let go: shown at once by the store, kept on the computer. One
    /// session onto another: 新建工作区 with both, for the owner to name.
    private func run(_ move: SidebarDrop.Move) {
        debugLog("[sidebar-drop] \(move)")
        if case .group(let target, let dragged) = move {
            onThisHost()
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
                    if let ws { model.sidebarExpanded.insert(expandKey(ws)) }
                    try await store.moveSession(id, to: ws, index: index)
                case .group: break
                }
            } catch {
                actions.on(store, host: hostID)
                actions.dropFailure = Copy.error(error)
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

    private func expandKey(_ workspace: String) -> String { WindowModel.SidebarPick.expandKey(host: hostID, workspace: workspace) }

    private func isExpanded(_ node: SidebarTree.WorkspaceNode) -> Bool { model.sidebarExpanded.contains(expandKey(node.id)) }

    private func toggle(_ node: SidebarTree.WorkspaceNode) {
        let key = expandKey(node.id)
        withAnimation(.snappy) {
            if model.sidebarExpanded.contains(key) { model.sidebarExpanded.remove(key) } else { model.sidebarExpanded.insert(key) }
        }
    }

    // MARK: menus

    @ViewBuilder private func sessionMenu(_ pal: Pal) -> some View {
        OpenInNewWindowButton(conversation: .pal(pal.id))
        Button("重命名", systemImage: "pencil") {
            actions.on(store, host: hostID)
            actions.renaming = pal
        }
        .disabled(!store.connection.isOnline)
        if store.workspacesSupported == true {
            Menu("移到工作区", systemImage: "square.grid.2x2") {
                ForEach(store.workspaces.filter { $0.id != pal.workspaceId }) { w in
                    Button(w.title(pals: store.pals)) { Task { try? await store.moveSession(pal.id, to: w.id) } }
                }
                Button("新建工作区…") {
                    onThisHost()
                    model.newWorkspace = [pal.id]
                }
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
        Button("结束会话", systemImage: "stop.circle", role: .destructive) {
            actions.on(store, host: hostID)
            actions.ending = pal
        }
        .disabled(!store.connection.isOnline)
    }

    @ViewBuilder private func workspaceMenu(_ w: Workspace) -> some View {
        OpenInNewWindowButton(conversation: .workspace(w.id))
        Button("重命名", systemImage: "pencil") {
            actions.on(store, host: hostID)
            actions.workspaceName = w.name
            actions.renamingWorkspace = w
        }
        .disabled(!store.connection.isOnline)
        Button("删除工作区", systemImage: "trash", role: .destructive) {
            actions.on(store, host: hostID)
            actions.deleting = w
        }
        .disabled(!store.connection.isOnline)
    }
}

/// A computer's name over its section: the chevron that folds it, a dot
/// (green online, gray not), the name; folded, what waits there on the
/// right. Its menu: 在新窗口中打开 (iPads and the Mac), 上移 / 下移.
private struct HostHeader: View {
    let hostID: String
    let collapsed: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let online = model.isOnline(hostID)
        let name = model.displayName(hostID)
        Button {
            withAnimation(.snappy) { model.app.setHostCollapsed(hostID, !collapsed) }
        } label: {
            HStack(spacing: 6) {
                SidebarChevron(expanded: !collapsed, small: true)
                Circle()
                    .fill(online ? StatusDot.color(.done) : Color(uiColor: .systemGray3))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(online ? 0.85 : 0.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if collapsed {
                    WaitingBadge(count: model.app.waitingTotal(hostID))
                }
            }
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .accessibilityIdentifier("host-header-\(hostID)")
        .accessibilityLabel(Text(verbatim: "\(name), \(online ? String(localized: "在线") : String(localized: "离线"))"))
        .accessibilityHint(collapsed ? String(localized: "展开") : String(localized: "收起"))
        .contextMenu {
            if UIApplication.shared.supportsMultipleScenes {
                Button("在新窗口中打开", systemImage: "macwindow.badge.plus") {
                    openWindow(value: WindowTarget(.palo, host: hostID))
                }
            }
            if model.app.canMoveHost(hostID, by: -1) || model.app.canMoveHost(hostID, by: 1) {
                Button("上移", systemImage: "arrow.up") { withAnimation(.snappy) { model.app.moveHost(hostID, by: -1) } }
                    .disabled(!model.app.canMoveHost(hostID, by: -1))
                Button("下移", systemImage: "arrow.down") { withAnimation(.snappy) { model.app.moveHost(hostID, by: 1) } }
                    .disabled(!model.app.canMoveHost(hostID, by: 1))
            }
        }
    }
}

/// An offline computer's rows, faded (they still open, on what was kept).
private struct HostRowDim: ViewModifier {
    let dimmed: Bool
    func body(content: Content) -> some View { content.opacity(dimmed ? 0.5 : 1) }
}

extension View {
    /// A sidebar row's tag, and its id for bringing it back into view.
    func sidebarPick(_ pick: WindowModel.SidebarPick) -> some View {
        tag(pick).id(pick)
    }
}

extension EnvironmentValues {
    /// The computer of the sidebar section a row is in (nil: the window's own).
    @Entry var sidebarHost: String? = nil
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

/// The big orb is the orb's resting place while the sidebar is shown.
private struct OrbHomeIfDocked: ViewModifier {
    @Environment(WindowModel.self) private var model
    var enabled = true

    func body(content: Content) -> some View {
        // Phones: never. The list stays alive under Palo's page, so it would
        // keep claiming the place off screen, and the orb would fly in from
        // there, or from nowhere; Palo's page drops it from its own bar.
        if model.layout == .phone || !enabled { content } else { content.paloOrbHome() }
    }
}

/// Palo: the orb and the name, big; under it what it did last, or how many
/// sessions wait on the owner; what waits on the owner in its own
/// conversation as the count. With several computers, each section's own
/// (its computer's orb, in its color).
private struct PaloItem: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    let hostID: String?
    /// Sessions (anywhere) waiting on the owner.
    let waitingSessions: Int

    var body: some View {
        let line = store.agentStatusLine
        let own = hostID == nil || hostID == model.activeHostID
        SidebarRowLayout {
            AssistantAvatar(theme: hostID.map(model.theme(for:)) ?? model.currentTheme, hostID: hostID ?? model.activeHostID, bleed: 1.3)
                .frame(width: 30, height: 30)
                // Only the window's own computer's is where its orb rests.
                .modifier(OrbHomeIfDocked(enabled: own))
        } title: {
            Text(name)
        } subtitle: {
            Text(secondLine(line))
                .foregroundStyle(line.kind == .offline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        } trailing: {
            // The count opens the list it counts (the row still opens the conversation).
            WaitingBadge(count: waiting)
                .simultaneousGesture(TapGesture().onEnded {
                    if !own { model.open(.palo, on: hostID) } else { model.openPalo() }
                    model.openPendingList()
                })
        }
        .accessibilityElement(children: .combine)
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

    /// What waits on the owner on this computer: the open items of 等你的事,
    /// the list the capsule and the orb count (cards, proposals, drafts and
    /// tasks are all items there).
    private var waiting: Int { store.openPending.count }
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
                SidebarChevron(expanded: expanded)
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

/// The open/close arrow of a sidebar group. The Mac draws the app at 77 %,
/// where an 11 pt gray chevron all but vanished (11-05): there it is larger,
/// bolder and darker.
private struct SidebarChevron: View {
    let expanded: Bool
    /// A computer's name over its section: a size down, as the header's text.
    var small = false

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: Platform.isMac ? (small ? 11 : 14) : (small ? 10 : 11), weight: Platform.isMac ? .bold : .semibold))
            .foregroundStyle(Platform.isMac ? AnyShapeStyle(Color.primary.opacity(0.6)) : AnyShapeStyle(.secondary))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: small ? 14 : (Platform.isMac ? 22 : 20), height: small ? 20 : 28)
    }
}

/// 更早的会话 N: the sessions put away for lack of use, opened in place.
private struct EarlierRow: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 2) {
                SidebarChevron(expanded: expanded)
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
                    Button("添加好友…", systemImage: "person.badge.plus") { model.showAllyInvite = true }
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

/// 电脑与设备: the last row, quiet (secondary), like 最近的对话.
private struct DevicesListRow: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        SidebarRowLayout {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        } title: {
            Text("主机与设备")
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
            WaitingBadge(count: store.allyPendingCount(ally.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Copy.allyPresence(ally))
    }
}
