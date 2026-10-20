import PaloAllyKit
import SwiftUI

// Where the right pane (workbench-prd §7) is opened from: its button, a path
// or a link tapped in a reply, a 成果 item, a session's 文件. Each goes to
// the pane's tabs of the page that is open (`PaneTabsHub`, kept on the
// computer), and shows the pane: beside the page on wide windows. On phones
// there are no tabs: the pane is one page (PhonePane), and what is opened
// is a full-screen modal (PaneModal).

extension AppModel {
    /// Whose tabs the open page uses: `palo`, `pal:<id>`, `ws:<id>`; nil on
    /// pages without a pane (an Ally, 以前的, devices).
    var paneKey: String? {
        switch selection ?? .palo {
        case .palo: PaneTabsKey.palo
        case .pal(let id): PaneTabsKey.session(id)
        case .workspace(let id): PaneTabsKey.workspace(id)
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
        if let id = activeTiles[workspaceID], ws.memberIds.contains(id) { return id }
        return tree(of: ws).flatMap { LayoutTree.leafOrder(of: $0).first }
    }

    /// The session a workspace's files belong to (nil elsewhere).
    var paneSessionID: String? {
        if case .workspace(let id)? = selection { return activeTile(in: id) }
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
            if selection != .palo { openPalo() }
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

    /// Where taps in replies go (set once the main screen is up).
    func installPaneOpeners() {
        PaneOpeners.file = { [weak self] target in self?.openFileInPane(target) ?? false }
        PaneOpeners.web = { [weak self] url in self?.openWebInPane(url) }
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
    /// A tile's details are open (per tile; nil outside a tiling: `AppModel.detailShown`).
    @Entry var tileDetail: Binding<Bool>? = nil
    /// Set on the page inside a workspace's tile.
    @Entry var tile: TileContext? = nil
}

/// What a page inside a tile knows of it: whose it is and whether it is the one in use.
struct TileContext: Equatable {
    let id: String
    var isActive: Bool
}

extension AppModel {
    /// Open or close the details: the tile's own, else the page's.
    func setDetail(_ on: Bool, tile: Binding<Bool>?) {
        if let tile { tile.wrappedValue = on } else { detailShown = on }
    }
}
