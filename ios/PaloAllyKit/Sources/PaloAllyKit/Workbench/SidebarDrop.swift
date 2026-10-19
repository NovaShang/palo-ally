import Foundation

/// What a drag in the sidebar does (the owner's manual order, workbench-rpc
/// `workbench.order.set`, `workspaces.move`, `workspaces.update`). Pure: the
/// view works out which row and which part of it the pointer is over, and this
/// says what the drop means.
public enum SidebarDrop {
    /// What is being dragged.
    public enum Item: Hashable, Sendable {
        case session(String)
        case workspace(String)

        /// Carried by the drag as text.
        public var token: String {
            switch self {
            case .session(let id): "session:\(id)"
            case .workspace(let id): "workspace:\(id)"
            }
        }

        public init?(token: String) {
            if token.hasPrefix("session:") { self = .session(String(token.dropFirst(8))) }
            else if token.hasPrefix("workspace:") { self = .workspace(String(token.dropFirst(10))) }
            else { return nil }
        }
    }

    /// The row it is over.
    public enum Target: Hashable, Sendable {
        /// An ordinary session (in no workspace).
        case session(String)
        /// A session inside a workspace.
        case member(String, workspace: String)
        case workspace(String)
        /// The 会话 header: the top of the ordinary sessions.
        case sessionsTop
    }

    /// Which part of the row: its top, its middle (onto it), its bottom.
    public enum Zone: Hashable, Sendable { case before, onto, after }

    /// The zone for a pointer `y` down a row `height` tall. A row that cannot
    /// be dropped onto has only a top and a bottom half.
    public static func zone(y: Double, height: Double, allowsOnto: Bool) -> Zone {
        guard height > 0 else { return .after }
        let f = min(max(y / height, 0), 1)
        if allowsOnto { return f < 0.28 ? .before : f > 0.72 ? .after : .onto }
        return f < 0.5 ? .before : .after
    }

    /// Whether the target can take a drop of this kind at all, and onto it.
    public static func accepts(_ item: Item, on target: Target) -> Bool {
        switch (item, target) {
        case (.session, .session), (.session, .member), (.session, .workspace), (.session, .sessionsTop): true
        case (.workspace, .workspace): true
        default: false
        }
    }

    /// Whether the target has a middle that means 「onto」: a session onto an
    /// ordinary session makes a workspace; onto a workspace row, goes in it.
    public static func allowsOnto(_ item: Item, on target: Target) -> Bool {
        switch (item, target) {
        case (.session, .session), (.session, .workspace): true
        default: false
        }
    }

    public enum Move: Equatable, Sendable {
        /// The ordinary sessions in this order (`workbench.order.set`).
        case reorderSessions([String])
        case reorderWorkspaces([String])
        case reorderMembers(workspace: String, ids: [String])
        /// Into a workspace at an index, or out of one (nil) to an index in the order.
        case moveSession(String, to: String?, index: Int?)
        /// Two sessions into a new workspace: the one dropped on, then the dragged one.
        case group(target: String, dragged: String)
    }

    /// What dropping `item` on `zone` of `target` does, or nil for nothing.
    public static func plan(_ item: Item, on target: Target, zone: Zone, tree: SidebarTree, sessionOrder: [String]?) -> Move? {
        guard accepts(item, on: target) else { return nil }
        let loose = tree.sessions.map(\.id)
        switch (item, target) {
        case (.session(let s), .session(let t)):
            guard s != t else { return nil }
            if zone == .onto { return .group(target: t, dragged: s) }
            if loose.contains(s) { return .reorderSessions(placed(s, in: loose, beside: t, after: zone == .after)) }
            // Out of a workspace, to a place in the order.
            let full = sessionOrder ?? loose
            let at = (full.firstIndex(of: t) ?? 0) + (zone == .after ? 1 : 0)
            return .moveSession(s, to: nil, index: at)

        case (.session(let s), .sessionsTop):
            if loose.first == s { return nil }
            if loose.contains(s) { return .reorderSessions([s] + loose.filter { $0 != s }) }
            return .moveSession(s, to: nil, index: 0)

        case (.session(let s), .member(let t, let ws)):
            guard s != t, let node = tree.workspaces.first(where: { $0.id == ws }) else { return nil }
            let members = node.members.map(\.id)
            if members.contains(s) {
                return .reorderMembers(workspace: ws, ids: placed(s, in: members, beside: t, after: zone == .after))
            }
            let at = (members.firstIndex(of: t) ?? members.count) + (zone == .after ? 1 : 0)
            return .moveSession(s, to: ws, index: at)

        case (.session(let s), .workspace(let w)):
            guard let node = tree.workspaces.first(where: { $0.id == w }), !node.members.contains(where: { $0.id == s }) else { return nil }
            return .moveSession(s, to: w, index: nil)

        case (.workspace(let w), .workspace(let t)):
            guard w != t else { return nil }
            let ids = tree.workspaces.map(\.id)
            guard ids.contains(w) else { return nil }
            let order = placed(w, in: ids, beside: t, after: zone != .before)
            return order == ids ? nil : .reorderWorkspaces(order)

        default:
            return nil
        }
    }

    /// `moving` taken out of `ids` and put just before or after `target`.
    static func placed(_ moving: String, in ids: [String], beside target: String, after: Bool) -> [String] {
        var out = ids.filter { $0 != moving }
        let at = (out.firstIndex(of: target) ?? out.count - 1) + (after ? 1 : 0)
        out.insert(moving, at: min(max(at, 0), out.count))
        return out
    }
}
