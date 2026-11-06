import PaloAllyKit
import SwiftUI
import UIKit

// 文档分屏 (the Mac and iPads): one document as a card of its own in a
// workspace, beside its sessions (`DocumentLeaf` in the layout). The card
// shows the right pane's own page for it (FilePage, ArtifactDetailView)
// under a header of the cards' measures: its name, and the page's ⋯ level
// with it holding the card's entries too. A document's tab gets there by
// being dragged from the right pane onto the canvas, or by 在分屏中打开 in
// its menus; 在右侧栏打开 sends it back.

// MARK: - what the pages read

/// A document's page inside a card: it starts below the card's header and
/// its ⋯ sits in the header, `menuTrailing` in from the card's edge.
struct DocumentCardChrome: Equatable {
    var menuTrailing: CGFloat = PaneMetrics.buttonInset
}

/// One more entry for a document's ⋯ (在分屏中打开; a card's 在右侧栏打开 and 关闭卡片).
struct DocumentMenuItem: Identifiable {
    let title: String
    let systemImage: String
    let action: () -> Void
    var id: String { title }
}

extension EnvironmentValues {
    /// Set on a document's page inside a workspace's card.
    @Entry var documentCard: DocumentCardChrome? = nil
    /// The entries a document's ⋯ adds after its own.
    @Entry var documentMenu: [DocumentMenuItem] = []
}

/// A document's ⋯ entries from around it, after a line.
struct DocumentMenuItems: View {
    @Environment(\.documentMenu) private var items

    var body: some View {
        if !items.isEmpty {
            Divider()
            ForEach(items) { item in
                Button(action: item.action) {
                    Label { Text(verbatim: item.title) } icon: { Image(systemName: item.systemImage) }
                }
            }
        }
    }
}

extension View {
    /// A document's page in a card starts below the card's header.
    func documentCardContent() -> some View { modifier(DocumentCardContentInset()) }

    /// Where a document's floating ⋯ goes: 10 pt in from the pane's corner,
    /// or in a card's header, as far in from the top as a session card's.
    func documentMenuPlacement() -> some View { modifier(DocumentMenuPlacement()) }
}

private struct DocumentCardContentInset: ViewModifier {
    @Environment(\.documentCard) private var card

    func body(content: Content) -> some View {
        content.padding(.top, card == nil ? 0 : PaneMetrics.headerHeight)
    }
}

private struct DocumentMenuPlacement: ViewModifier {
    @Environment(\.documentCard) private var card

    func body(content: Content) -> some View {
        if let card {
            content.padding(.top, PaneMetrics.buttonTop).padding(.trailing, card.menuTrailing)
        } else {
            content.padding(10)
        }
    }
}

// MARK: - the card

/// A document's card in a workspace: the page the right pane shows for it,
/// under a header with its name, the page's ⋯ in the header's corner. A
/// file that isn't there any more (or an item of 成果 gone) says so calmly.
struct DocumentCardContent: View {
    let doc: DocumentLeaf
    let workspaceID: String
    let actions: PaneActions
    let corner: Bool
    @Environment(AppStore.self) private var store

    private var menuTrailing: CGFloat { PaneMetrics.buttonInset + (corner ? PaneMetrics.cornerShift : 0) }

    var body: some View {
        page
            .environment(\.documentCard, DocumentCardChrome(menuTrailing: menuTrailing))
            .environment(\.documentMenu, menu)
            .environment(\.placesAsColumns, false)
            .overlay(alignment: .top) { header }
            .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder private var page: some View {
        switch doc {
        case .file(let path):
            FilePage(target: FileTarget(scope: .root, path: path), inPane: true)
                .id(path)
        case .artifact(let id):
            if store.artifact(id: id) != nil {
                ArtifactDetailView(artifactID: id, inPane: true)
                    .id(id)
            } else {
                gone
                    .documentCardContent()
                    .overlay(alignment: .topTrailing) {
                        MacStripMenu(label: String(localized: "更多")) { DocumentMenuItems() }
                            .documentMenuPlacement()
                    }
            }
        }
    }

    private var gone: some View {
        ContentUnavailableView {
            Label { Text("这份成果已经不在了", tableName: "Files") } icon: { Image(systemName: "square.stack") }
        } description: {
            Text("可以关掉这张卡片。", tableName: "Files")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var menu: [DocumentMenuItem] {
        let id = doc.id
        let actions = actions
        return [
            DocumentMenuItem(title: String(localized: "在右侧栏打开", table: "Files"), systemImage: "sidebar.trailing") {
                actions.documentToPane(id)
            },
            DocumentMenuItem(title: String(localized: "关闭卡片", table: "Files"), systemImage: "xmark") {
                actions.closeDocument(id)
            },
        ]
    }

    /// The header, the cards' measures: a document's mark where a session's
    /// drop is, its name level with it. The page's ⋯ sits over its corner.
    private var header: some View {
        HStack(spacing: 0) {
            Image(systemName: DocumentCardContent.symbol(doc))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PaneMetrics.button, height: PaneMetrics.button)
                .padding(.leading, PaneMetrics.buttonInset)
            Text(verbatim: DocumentCardContent.name(doc, store: store))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, PaneMetrics.titleLeading - PaneMetrics.buttonInset - PaneMetrics.button)
            Spacer(minLength: 0)
        }
        .padding(.trailing, PaneMetrics.titleTrailing + (corner ? PaneMetrics.cornerShift : 0))
        .frame(height: PaneMetrics.headerHeight)
        .help(DocumentCardContent.path(doc))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tile-title-\(doc.id)")
    }

    /// What the card and a dragged tab's capsule call it.
    static func name(_ doc: DocumentLeaf, store: AppStore) -> String {
        switch doc {
        case .file(let path): (path as NSString).lastPathComponent
        case .artifact(let id): store.artifact(id: id)?.title.nilIfEmpty ?? String(localized: "成果")
        }
    }

    static func symbol(_ doc: DocumentLeaf) -> String {
        switch doc {
        case .file: "doc.text"
        case .artifact: "square.stack"
        }
    }

    static func path(_ doc: DocumentLeaf) -> String {
        switch doc {
        case .file(let path): path
        case .artifact: ""
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - a tab dragged onto the canvas

/// Where a document's tab dragged out of the right pane lands: the
/// workspace page on screen in this window sets it on its `WindowModel`
/// (`documentDrop`), the tab's drag reports the pointer in the window's
/// coordinates, and the canvas shows where it would go with the panes'
/// own drop zones and preview.
@MainActor
final class DocumentDropTarget {
    var handle: PaneCanvasHandle?

    private var canvas: PaneCanvasController? { handle?.controller }

    /// True when the canvas took it (a narrow one with more than two cards doesn't).
    func begin(_ doc: DocumentLeaf, info: TileInfo, at point: CGPoint) -> Bool {
        canvas?.beginDocumentDrag(doc.id, info: info, at: point) ?? false
    }

    func move(to point: CGPoint) {
        canvas?.moveDocumentDrag(to: point)
    }

    /// Let go: true when the document is now a card (placed, or already one).
    func end(at point: CGPoint, commit: Bool) -> Bool {
        canvas?.endDocumentDrag(at: point, commit: commit) ?? false
    }

    /// The card is pointed out (asked for again while already open).
    func flash(_ id: String) {
        canvas?.flash(id)
    }
}

// MARK: - opening, sending back, closing

extension WindowModel {
    /// 在分屏中打开: the document as a card beside the active pane, to its
    /// right; one already a card is pointed out instead. Its tab leaves the
    /// workspace's right pane.
    func openInSplit(_ doc: DocumentLeaf, in workspaceID: String) async throws {
        guard let store, let ws = store.workspace(id: workspaceID) else { return }
        let id = doc.id
        let shown = tree(of: ws)
        activate(tile: id, in: workspaceID)
        if let shown, LayoutTree.leafOrder(of: shown).contains(id) {
            closeDocumentTab(doc, in: workspaceID)
            documentDrop?.flash(id)
            return
        }
        var placed: LayoutTree.Node?
        if let shown {
            if let active = activeTile(in: workspaceID) {
                placed = LayoutTree.splitting(pane: active, adding: id, horizontal: true, in: shown)
            }
            placed = placed ?? LayoutTree.inserting(pane: id, into: shown)
        } else {
            placed = LayoutTree.single(pane: id)
        }
        if let json = placed?.json { _ = try await store.updateWorkspace(id: workspaceID, layout: json) }
        closeDocumentTab(doc, in: workspaceID)
    }

    /// 在右侧栏打开: the card goes, the document opens as a tab of the
    /// workspace's right pane, and the pane shows.
    func documentToPane(_ id: String, in workspaceID: String) async throws {
        guard let doc = DocumentLeaf(id: id) else { return }
        try await closeDocumentCard(id, in: workspaceID)
        let key = PaneTabsKey.workspace(workspaceID)
        editPane(key) { hub in
            switch doc {
            case .file(let path): hub.openPreview(key, path: path)
            case .artifact(let a): hub.openArtifact(key, id: a)
            }
            hub.setOpen(key, true)
        }
    }

    /// 关闭卡片: the card off the layout, its neighbours taking the room as
    /// for a session's.
    func closeDocumentCard(_ id: String, in workspaceID: String) async throws {
        guard let store, let ws = store.workspace(id: workspaceID), let shown = tree(of: ws),
              LayoutTree.leafOrder(of: shown).contains(id) else { return }
        let rest = LayoutTree.removing(pane: id, from: shown)
        _ = try await store.updateWorkspace(id: workspaceID, layout: rest?.json ?? .null)
    }

    /// The document's tab off the workspace's right pane (it is a card now).
    func closeDocumentTab(_ doc: DocumentLeaf, in workspaceID: String) {
        let key = PaneTabsKey.workspace(workspaceID)
        guard let hub = paneHub, let i = hub.state(for: key).index(of: doc) else { return }
        editPane(key) { $0.close(key, at: i) }
    }
}
