import Foundation

/// The phone's quick-switch strip (a port of Bento's pane tab bar): which
/// conversations it lists and who is next. Pure.
public enum QuickSwitch {
    /// One chip.
    public enum Member: Hashable, Sendable {
        case palo
        case session(String)

        public var sessionID: String? {
            if case .session(let id) = self { id } else { nil }
        }
    }

    /// In a workspace: its members in order. Otherwise Palo first, then the
    /// ordinary (unfolded) sessions in the sidebar's order. A current session
    /// the lists would leave out (folded) still gets its chip, last.
    public static func members(current: Member, pals: [Pal], workspaces: [Workspace]) -> [Member] {
        let tree = SidebarTree.build(pals: pals, workspaces: workspaces)
        var out: [Member]
        if case .session(let id) = current,
           let node = tree.workspaces.first(where: { $0.members.contains { $0.id == id } }) {
            out = node.members.map { .session($0.id) }
        } else {
            out = [.palo] + tree.sessions.map { .session($0.id) }
            if case .session = current, !out.contains(current) { out.append(current) }
        }
        return out
    }

    /// The chip a swipe lands on: `step` -1 is the previous, +1 the next.
    /// Nil at either end (no wrap) or when `current` isn't listed.
    public static func neighbor(of current: Member, step: Int, in members: [Member]) -> Member? {
        guard let i = members.firstIndex(of: current) else { return nil }
        let j = i + step
        return members.indices.contains(j) ? members[j] : nil
    }

    /// Where to go once `ended` is gone from the strip: its neighbor to the
    /// left, else the right, else Palo.
    public static func landing(after ended: Member, in members: [Member]) -> Member {
        guard let i = members.firstIndex(of: ended) else { return .palo }
        if i > 0 { return members[i - 1] }
        return members.count > 1 ? members[1] : .palo
    }
}
