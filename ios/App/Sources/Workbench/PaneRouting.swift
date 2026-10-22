import PaloAllyKit
import SwiftUI

// Where the right pane (workbench-prd §7) is opened from: its button, a path
// or a link tapped in a reply, a 成果 item, a session's 文件. Each goes to
// the pane's tabs of the page that is open (`PaneTabsHub`, kept on the
// computer), and shows the pane: beside the page on wide windows. On phones
// there are no tabs: the pane is one page (PhonePane), and what is opened
// is a full-screen modal (PaneModal).

extension WindowModel {
    /// Whose tabs the open page uses: `palo`, `pal:<id>`, `ws:<id>`; nil on
    /// pages without a pane (an Ally, 以前的, devices).
    var paneKey: String? {
        switch selection ?? .palo {
        case .palo: PaneTabsKey.palo
        case .pal(let id): PaneTabsKey.session(id)
        // Palo's pane in it: Palo's own tabs while it is the one in use.
        case .workspace(let id): activeTile(in: id) == LayoutTree.paloPane ? PaneTabsKey.palo : PaneTabsKey.workspace(id)
        default: nil
        }
    }

    var paneHub: PaneTabsHub? { store.map { PaneTabsHub.shared(for: $0) } }

    /// The workspace's tiling as it is shown: the stored tree fitted to its members.
    func tree(of workspace: Workspace) -> LayoutTree.Node? {
        LayoutTree.reconciled(LayoutTree.Node(json: workspace.layout), members: workspace.memberIds)
    }

    /// The active tile of a workspace: the one last chosen, else the first.
    func activeTile(in workspaceID: String) -> String? {
        guard let ws = store?.workspace(id: workspaceID) else { return nil }
        let order = tree(of: ws).map(LayoutTree.leafOrder(of:)) ?? []
        if let id = activeTiles[workspaceID], order.contains(id) { return id }
        return order.first
    }

    /// Whether a workspace shows Palo as one of its panes.
    func showsPalo(in workspaceID: String) -> Bool {
        guard let ws = store?.workspace(id: workspaceID), let tree = tree(of: ws) else { return false }
        return LayoutTree.leafOrder(of: tree).contains(LayoutTree.paloPane)
    }

    /// The session a workspace's files belong to (nil elsewhere, and while Palo's pane is the one in use).
    var paneSessionID: String? {
        if case .workspace(let id)? = selection, let tile = activeTile(in: id), tile != LayoutTree.paloPane { return tile }
        return nil
    }

    /// Whether the open page's pane shows.
    var paneIsOpen: Bool {
        guard libraryBeside else { return paneCover }
        guard let key = paneKey, let hub = paneHub else { return false }
        return hub.state(for: key).open
    }

    func setPane(open: Bool) {
        guard libraryBeside else { paneCover = open; return }
        guard let key = paneKey else { return }
        paneHub?.setOpen(key, open)
    }

    /// The pane's button (and ⌘2).
    func togglePane() {
        if paneKey == nil { openPalo() }
        setPane(open: !paneIsOpen)
    }

    /// Something to show in the pane of the open page (Palo's when the page has none).
    /// Phones: no tabs, so an artifact asked for through `libraryPath` is a modal
    /// and anything else is 成果 in the pane page.
    func openInPane(_ edit: (PaneTabsHub, String) -> Void) {
        if paneKey == nil { openPalo() }
        guard let key = paneKey, let hub = paneHub else { return }
        if libraryBeside {
            edit(hub, key)
            return
        }
        if libraryPath.count == 1, let id = libraryPath.first, let store {
            libraryPath = []
            PaneModal.artifact(id, model: self, store: store)
            return
        }
        PhonePaneState.shared.segment = .library
        paneCover = true
    }

    /// The key a session's files and pages go to: its workspace's when that
    /// is the open page (it becomes the active tile), else its own page.
    private func paneKey(forSession id: String) -> String {
        if case .workspace(let w)? = selection, store?.workspace(id: w)?.memberIds.contains(id) == true {
            activeTiles[w] = id
            return PaneTabsKey.workspace(w)
        }
        if selection != .pal(id) { open(.pal(id)) }
        return PaneTabsKey.session(id)
    }

    /// A session's 文件.
    func openPalFiles(_ palID: String) {
        let key = paneKey(forSession: palID)
        if libraryBeside {
            paneHub?.openFiles(key)
        } else {
            PhonePaneState.shared.segment = .files
            paneCover = true
        }
    }

    /// A file tapped in a reply: a preview tab (phones: a full-screen modal).
    /// false: not one the pane shows.
    func openFileInPane(_ target: FileTarget) -> Bool {
        guard let hub = paneHub else { return false }
        if !libraryBeside {
            guard let store, target.scope.kind == .pal || target.scope.kind == .palo else { return false }
            PaneModal.file(target, model: self, store: store)
            return true
        }
        let key: String
        switch target.scope.kind {
        case .pal:
            guard let id = target.scope.id else { return false }
            key = paneKey(forSession: id)
        case .palo:
            // Palo's pane of the open workspace: it stays, its pane becomes the one in use.
            if case .workspace(let w)? = selection, showsPalo(in: w) {
                activate(tile: LayoutTree.paloPane, in: w)
            } else if selection != .palo {
                openPalo()
            }
            key = PaneTabsKey.palo
        default:
            return false
        }
        hub.openPreview(key, path: target.path)
        return true
    }

    /// A web link tapped in a reply: a page tab (phones: the system's browser view).
    func openWebInPane(_ url: URL) {
        if !libraryBeside {
            if !PaneModal.web(url) { UIApplication.shared.open(url) }
            return
        }
        openInPane { $0.openWeb($1, url: url.absoluteString) }
    }

    /// Where taps in replies go (set once the main screen is up): the window
    /// clicked in, which is the one used last by then.
    func installPaneOpeners() {
        PaneOpeners.file = { [weak app] target in app?.frontWindow?.openFileInPane(target) ?? false }
        PaneOpeners.web = { [weak app] url in app?.frontWindow?.openWebInPane(url) }
    }

    /// A tile became the one the owner works in.
    func activate(tile id: String, in workspaceID: String) {
        if activeTiles[workspaceID] != id { activeTiles[workspaceID] = id }
    }
}

/// Hooks for the UIKit text view, which has no environment.
@MainActor enum PaneOpeners {
    static var file: ((FileTarget) -> Bool)?
    static var web: ((URL) -> Void)?
}

extension EnvironmentValues {
    /// A tile's details are open (per tile; nil outside a tiling: `WindowModel.detailShown`).
    @Entry var tileDetail: Binding<Bool>? = nil
    /// Set on the page inside a workspace's tile.
    @Entry var tile: TileContext? = nil
}

/// What a page inside a tile knows of it: whose it is and whether it is the one in use.
struct TileContext: Equatable {
    let id: String
    var isActive: Bool
}

extension WindowModel {
    /// Open or close the details: the tile's own, else the page's.
    func setDetail(_ on: Bool, tile: Binding<Bool>?) {
        if let tile { tile.wrappedValue = on } else { detailShown = on }
    }
}

/// Where a pane added to a split workspace goes: beside `pane`, to its
/// right (`horizontal`) or below it.
struct PanePlacement: Equatable {
    var pane: String
    var horizontal: Bool
}

extension WindowModel {
    /// A session into a split workspace as a pane of its own, beside
    /// `placement`'s pane (else where the layout puts a newcomer), and the
    /// pane to talk to. A new session already in it is only placed.
    func addPane(_ id: String, to workspaceID: String, placement: PanePlacement?) async throws {
        guard let store else { return }
        if id == LayoutTree.paloPane {
            try await addPalo(to: workspaceID, placement: placement)
            return
        }
        if store.pal(id: id)?.workspaceId != workspaceID {
            try await store.moveSession(id, to: workspaceID)
        }
        if let placement, placement.pane != id, let ws = store.workspace(id: workspaceID), let shown = tree(of: ws) {
            // The tiling without it (it may already be in, where newcomers go).
            let without = LayoutTree.leafOrder(of: shown).contains(id) ? LayoutTree.removing(pane: id, from: shown) : shown
            if let without,
               let placed = LayoutTree.splitting(pane: placement.pane, adding: id, horizontal: placement.horizontal, in: without),
               let json = placed.json {
                _ = try await store.updateWorkspace(id: workspaceID, layout: json)
            }
        }
        activate(tile: id, in: workspaceID)
    }

    /// Palo into a split workspace as a pane (a view of it: it stays at the
    /// top of the sidebar and joins no workspace), beside `placement`'s pane
    /// or where a newcomer goes.
    private func addPalo(to workspaceID: String, placement: PanePlacement?) async throws {
        guard let store, let ws = store.workspace(id: workspaceID) else { return }
        let palo = LayoutTree.paloPane
        let shown = tree(of: ws)
        var placed: LayoutTree.Node?
        if let shown, LayoutTree.leafOrder(of: shown).contains(palo) {
            placed = nil
        } else if let shown {
            if let placement, placement.pane != palo {
                placed = LayoutTree.splitting(pane: placement.pane, adding: palo, horizontal: placement.horizontal, in: shown)
            }
            placed = placed ?? LayoutTree.inserting(pane: palo, into: shown)
        } else {
            placed = LayoutTree.single(pane: palo)
        }
        if let json = placed?.json { _ = try await store.updateWorkspace(id: workspaceID, layout: json) }
        activate(tile: palo, in: workspaceID)
    }

    /// Palo's pane off a workspace (Palo itself goes on, at the top of the sidebar).
    func removePalo(from workspaceID: String) async throws {
        guard let store, let ws = store.workspace(id: workspaceID), let shown = tree(of: ws),
              LayoutTree.leafOrder(of: shown).contains(LayoutTree.paloPane) else { return }
        let next = LayoutTree.focusAfterClosing(LayoutTree.paloPane, in: shown)
        let rest = LayoutTree.removing(pane: LayoutTree.paloPane, from: shown)
        _ = try await store.updateWorkspace(id: workspaceID, layout: rest?.json ?? .null)
        if activeTiles[workspaceID] == LayoutTree.paloPane || activeTiles[workspaceID] == nil, let next {
            activate(tile: next, in: workspaceID)
        }
    }

    /// 新开一个会话… for a split workspace, its pane going to `placement`.
    func newSessionAsPane(in workspaceID: String, placement: PanePlacement?) {
        newSessionIntoWorkspace = workspaceID
        newSessionPlacement = placement
        newSession = true
    }

    /// ⌘D / ⌘⇧D: a new session split off the active pane of the open
    /// workspace, to its right or below it.
    func splitActivePane(horizontal: Bool) {
        guard case .workspace(let id)? = selection, layout == .split, let active = activeTile(in: id) else { return }
        newSessionAsPane(in: id, placement: PanePlacement(pane: active, horizontal: horizontal))
    }
}
