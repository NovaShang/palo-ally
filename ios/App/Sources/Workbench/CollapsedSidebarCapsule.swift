import PaloAllyKit
import SwiftUI
import UIKit

extension WindowModel {
    /// The sidebar shown or put away: the window's sidebar button, ⌃⌘S and
    /// the capsule's button all come here.
    func toggleSidebar() {
        debugLog("[sidebar] \(columnVisibility == .detailOnly ? "shown" : "put away") in \(traceName)")
        // The split view's own animation is half a second; nothing in the
        // columns is laid out again until it is over.
        columnsMove(for: 0.55)
        withAnimation(.snappy) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// Sidebar collapsed on a large screen: the capsule stands in for it.
    var sidebarCollapsed: Bool { layout == .split && columnVisibility == .detailOnly }

    /// Sessions waiting on the owner, then the ones that finished something
    /// not yet looked at, each the latest first.
    func attentionSessions(in store: AppStore) -> (waiting: [Pal], done: [Pal]) {
        func latest(_ kind: StatusDotKind) -> [Pal] {
            store.pals.filter { $0.dot == kind }.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        }
        return (latest(.waiting), latest(.done))
    }

    /// A session picked in the capsule's list: the active tile when it is in
    /// the open workspace, else its own page.
    func jump(toSession pal: Pal) {
        if case .workspace(let w)? = selection, pal.workspaceId == w {
            activate(tile: pal.id, in: w)
        } else {
            openPal(pal.id)
        }
    }
}
