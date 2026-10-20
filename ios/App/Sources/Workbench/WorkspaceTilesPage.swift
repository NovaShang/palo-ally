import PaloAllyKit
import SwiftUI

/// A workspace's page (workbench-prd §5.3, docs/workbench-design/split-final.html):
/// its sessions tiled on one canvas, flat panes with hairlines between them.
/// Each pane is the session's own page (`PalPage`, minus its chrome) under a
/// slim header, in a view graph of its own (`PaneRoot`). Every pane looks the
/// same: the current one (where the keyboard and the right pane go) is only
/// remembered. The layout is kept on the computer.
struct WorkspaceTilesPage: View {
    let workspaceID: String
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.scenePhase) private var scenePhase
    /// The pane whose details are open.
    @State private var details = TileDetails()
    /// What the panes' ⋯ menus do (set here, read by every pane).
    @State private var actions = PaneActions()
    /// What the panes get from this graph that changes (they are hosted apart).
    @State private var bridge = PaneBridge()
    @State private var canvas = PaneCanvasHandle()
    /// The pane asked to end (its session, after a confirm).
    @State private var closing: String?
    @State private var ending = false
    @State private var failure: String?
    @State private var renaming: Pal?
    /// The layout just kept, shown until the stored one catches up.
    @State private var pending: LayoutTree.Node?

    private var workspace: Workspace? { store.workspace(id: workspaceID) }

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("TilesPage")
        #endif
        Group {
            if let workspace, let tree = model.tree(of: workspace) {
                TiledWorkspaceView(
                    layout: pending ?? tree,
                    active: { model.activeTile(in: workspaceID) },
                    info: info,
                    accent: model.currentTheme.uiColor,
                    handle: canvas,
                    makePane: makePane,
                    onLayoutChange: save,
                    onActivate: { model.activate(tile: $0, in: workspaceID) },
                    onMoveFocus: moveFocus,
                    onCornerPane: { bridge.cornerPane = $0 })
            } else if workspace != nil {
                Text("这个工作区里没有会话了。")
                    .foregroundStyle(.secondary)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("这个工作区已经不在了。")
                    .foregroundStyle(.secondary)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { StatusBanner() }
        .overlay(alignment: .bottom) { closeConfirm }
        .palRename($renaming)
        .onAppear(perform: setUpActions)
        .onChange(of: scenePhase, initial: true) { _, phase in bridge.scenePhase = phase }
        .animation(.snappy, value: closing)
        // ⌘⌥→ / ⌘⌥←: the next and the previous tile.
        .background { focusKeys }
        // The title reads every session's name: in a modifier of its own, so
        // a session ticking doesn't re-render the page and all its tiles.
        .modifier(WorkspaceBar(workspaceID: workspaceID))
        .accessibilityIdentifier("workspace-page")
        #if DEBUG || PERF_HARNESS
        // `-demoType <keys per second>`: types into the active tile's draft,
        // as a keyboard would (perf measuring); clears every 60 characters.
        .task {
            let cps = UserDefaults.standard.double(forKey: "demoType")
            guard cps > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / cps))
                guard PerfSwitch.driving, let id = model.activeTile(in: workspaceID) else { continue }
                let draft = model.draftBinding(.pal(id))
                n += 1
                draft.wrappedValue = n % 60 == 0 ? "" : draft.wrappedValue + (n % 7 == 0 ? " " : "字")
            }
        }
        #endif
        .onChange(of: workspace == nil && store.workspacesSupported == true) { _, gone in
            if gone { model.showList() }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        }
    }

    // MARK: panes

    private func info(_ id: String) -> TileInfo {
        guard let pal = store.singlePal(id: id) else { return TileInfo(name: "") }
        return TileInfo(name: pal.displayName, dot: pal.dot)
    }

    /// A pane's own view graph: the page and everything it reads from
    /// around it, passed in (`PaneRoot`).
    private func makePane(_ id: String) -> UIViewController {
        let host = PaneHostingController(rootView: PaneRoot(id: id, workspaceID: workspaceID, model: model, store: store,
                                                          voice: voice, details: details, actions: actions, bridge: bridge))
        // The pane places its own header; only the keyboard pushes it (iPads).
        host.safeAreaRegions = .keyboard
        host.sizingOptions = []
        host.view.backgroundColor = .systemBackground
        return host
    }

    private func setUpActions() {
        let workspaceID = workspaceID
        actions.openPane = { id in
            model.activate(tile: id, in: workspaceID)
            model.setPane(open: true)
        }
        actions.openAlone = { model.openPal($0) }
        actions.rename = { id in renaming = store.singlePal(id: id) }
        actions.moveOut = { takeOut($0) }
        actions.closePane = { takeOut($0) }
        actions.end = { closing = $0 }
    }

    /// Off the canvas: the session goes on, on its own in the list.
    private func takeOut(_ id: String) {
        let next = workspace.flatMap { model.tree(of: $0) }.flatMap { LayoutTree.focusAfterClosing(id, in: $0) }
        Task {
            do {
                try await store.moveSession(id, to: nil)
                if model.activeTiles[workspaceID] == id || model.activeTiles[workspaceID] == nil, let next {
                    model.activate(tile: next, in: workspaceID)
                }
            } catch {
                failure = Copy.error(error)
            }
        }
    }

    // MARK: layout

    /// The tiling, as the owner left it, kept on the computer.
    private func save(_ tree: LayoutTree.Node) {
        guard let json = tree.json else { return }
        let id = workspaceID
        pending = tree
        Task {
            _ = try? await store.updateWorkspace(id: id, layout: json)
            pending = nil
        }
    }

    // MARK: focus

    @ViewBuilder private var focusKeys: some View {
        Group {
            Button("") { moveFocus(previous: false) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("") { moveFocus(previous: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func moveFocus(previous: Bool) {
        guard let workspace, let tree = model.tree(of: workspace), let active = model.activeTile(in: workspaceID),
              let next = LayoutTree.neighbor(of: active, previous: previous, in: tree) else { return }
        model.activate(tile: next, in: workspaceID)
        // No mark shows the current pane: the caret goes there.
        canvas.controller?.focusComposer(of: next)
    }

    // MARK: close

    @ViewBuilder private var closeConfirm: some View {
        if let id = closing, let pal = store.pal(id: id) {
            ConfirmPanel(title: Copy.spaced(String(localized: "结束「\(pal.displayName)」？")),
                         text: String(localized: "它会停下，之后还能从历史记录里接着聊。"),
                         action: String(localized: "结束会话"), working: ending,
                         cancel: { closing = nil }, confirm: { end(id) })
                .padding(16)
                .frame(maxWidth: 440)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func end(_ id: String) {
        guard !ending else { return }
        ending = true
        let next = workspace.flatMap { model.tree(of: $0) }.flatMap { LayoutTree.focusAfterClosing(id, in: $0) }
        Task {
            defer { ending = false }
            do {
                try await store.endSession(id: id)
                closing = nil
                if model.activeTiles[workspaceID] == id || model.activeTiles[workspaceID] == nil, let next {
                    model.activate(tile: next, in: workspaceID)
                }
            } catch {
                closing = nil
                failure = Copy.error(error)
            }
        }
    }
}

/// Which tile's details are open, with one binding per tile kept (like
/// `DraftBox`): the same value every time it is put in a tile's environment.
@MainActor
@Observable
final class TileDetails {
    var tile: String?
    @ObservationIgnored private var bindings: [String: Binding<Bool>] = [:]
    @ObservationIgnored lazy var open = Binding<String?>(get: { [unowned self] in self.tile },
                                                         set: { [unowned self] in self.tile = $0 })

    func binding(_ id: String) -> Binding<Bool> {
        if let b = bindings[id] { return b }
        let b = Binding<Bool>(get: { [unowned self] in self.tile == id },
                              set: { [unowned self] on in self.tile = on ? id : (self.tile == id ? nil : self.tile) })
        bindings[id] = b
        return b
    }
}

/// The workspace's title, 并排 and (off the Mac) the right pane's button.
/// The Mac has no navigation bar: its window toolbar holds the pane's button
/// and a strip at the page's top holds the rest.
private struct WorkspaceBar: ViewModifier {
    let workspaceID: String
    @Environment(AppStore.self) private var store
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        let workspace = store.workspace(id: workspaceID)
        let title = workspace?.title(pals: store.pals) ?? ""
        let count = workspace?.memberIds.count ?? 0
        bar(content
            .navigationTitle(title)
            .navigationSubtitle(String(localized: "\(count) 个会话")))
    }

    @ViewBuilder private func bar(_ content: some View) -> some View {
        if Platform.barInWindowToolbar {
            // The Mac: no navigation bar, no title strip (the sidebar names
            // the workspace; each tile has its own header), no 并排 button.
            // The tiles run up into the window's title bar row: this view
            // needs every point of height. Clear of the traffic lights and
            // the sidebar's capsule when the sidebar is away.
            content
                .toolbar(.hidden, for: .navigationBar)
                .padding(.top, model.sidebarCollapsed ? SidebarChrome.shared.titlebarMidY * 2 - 6 : 0)
                .ignoresSafeArea(.container, edges: .top)
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) { TileMenu(workspaceID: workspaceID, glass: false) }
                ToolbarItem(placement: .topBarTrailing) { PaneButton() }
            }
        }
    }
}

private struct PaneButton: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button { model.togglePane() } label: { Image(systemName: "sidebar.trailing") }
            .tint(.primary)
            .accessibilityLabel("右侧栏")
            .accessibilityIdentifier("pane-toggle")
    }
}

/// 并排: one more tile, from the sessions that aren't in this workspace, or a new one.
private struct TileMenu: View {
    let workspaceID: String
    let glass: Bool
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var failure: String?

    private var others: [Pal] { store.listedPals.filter { $0.workspaceId != workspaceID } }

    var body: some View {
        Menu {
            if !others.isEmpty {
                Section("已有的会话") {
                    ForEach(others) { pal in
                        Button(pal.displayName) { add(pal.id) }
                    }
                }
            }
            Button("新开一个会话…", systemImage: "plus") {
                model.newSessionIntoWorkspace = workspaceID
                model.newSession = true
            }
        } label: {
            if glass {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            } else {
                Image(systemName: "rectangle.split.2x1")
            }
        }
        .modifier(GlassMenuStyle(glass: glass))
        .disabled(!store.connection.isOnline)
        .tint(.primary)
        .accessibilityLabel("并排")
        .accessibilityIdentifier("workspace-tile")
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        }
    }

    private func add(_ id: String) {
        Task {
            do {
                try await store.moveSession(id, to: workspaceID)
                model.activate(tile: id, in: workspaceID)
            } catch {
                failure = Copy.error(error)
            }
        }
    }
}

private struct GlassMenuStyle: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 32)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}
