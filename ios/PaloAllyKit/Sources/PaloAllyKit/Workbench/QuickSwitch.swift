import Foundation

/// The phone's quick-switch strip (docs/workbench-design/quick-switch.html):
/// which sessions it lists and who is next. Only in a workspace: the strip
/// switches between its sessions, as tiles would on a larger screen. Pure.
public enum QuickSwitch {
    /// The sessions of the workspace `current` is in, in its order; empty
    /// when it is in none, or the workspace has nothing else to switch to.
    public static func members(current: String, pals: [Pal], workspaces: [Workspace]) -> [String] {
        let tree = SidebarTree.build(pals: pals, workspaces: workspaces)
        guard let node = tree.workspaces.first(where: { $0.members.contains { $0.id == current } }),
              node.members.count > 1 else { return [] }
        return node.members.map(\.id)
    }

    /// The session a swipe lands on: `step` -1 is the previous, +1 the next.
    /// Nil at either end (no wrap) or when `current` isn't listed.
    public static func neighbor(of current: String, step: Int, in members: [String]) -> String? {
        guard let i = members.firstIndex(of: current) else { return nil }
        let j = i + step
        return members.indices.contains(j) ? members[j] : nil
    }

    /// Where to go once `ended` is gone: its neighbor to the left, else the
    /// right; nil when it was the only one.
    public static func landing(after ended: String, in members: [String]) -> String? {
        guard let i = members.firstIndex(of: ended) else { return nil }
        if i > 0 { return members[i - 1] }
        return members.count > 1 ? members[1] : nil
    }
}
