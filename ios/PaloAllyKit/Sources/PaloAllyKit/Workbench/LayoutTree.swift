import Foundation

/// The workbench's tiling model, ported from Bento's `LayoutTree`: a tree of
/// fractional rects on a unit canvas ([0,1]x[0,1]). Leaves are sessions (their
/// ids are `String`s); the host stores the tree as is (docs/workbench-rpc.md,
/// "LayoutNode"). Every structure verb returns a fully renormalized tree.
public enum LayoutTree {
    /// The canvas aspect used to judge a pane's "longer edge" when inserting
    /// (a window is wider than it is tall).
    static let legacyCols = 160
    static let legacyRows = 48
    /// No pane may shrink below this fraction of the canvas on either axis.
    public static let minShare = 0.02

    public indirect enum Node: Equatable, Sendable {
        case leaf(id: String, w: Double, h: Double, x: Double, y: Double)
        case hsplit(w: Double, h: Double, x: Double, y: Double, children: [Node])
        case vsplit(w: Double, h: Double, x: Double, y: Double, children: [Node])

        var width: Double {
            switch self {
            case .leaf(_, let w, _, _, _), .hsplit(let w, _, _, _, _), .vsplit(let w, _, _, _, _): return w
            }
        }
        var height: Double {
            switch self {
            case .leaf(_, _, let h, _, _), .hsplit(_, let h, _, _, _), .vsplit(_, let h, _, _, _): return h
            }
        }
    }

    // MARK: - Canvas

    /// A fresh single-pane layout filling the unit canvas. `w`/`h` are
    /// ignored (legacy-signature shim — callers used to pass cell sizes).
    public static func single(pane id: String) -> Node {
        .leaf(id: id, w: 1, h: 1, x: 0, y: 0)
    }

    /// Renormalize a tree to the unit canvas. `w`/`h` are ignored (legacy
    /// shim — the canvas is always [0,1]); kept because callers still pass
    /// their vestigial cols/rows. Also heals legacy cell trees.
    public static func resized(_ node: Node) -> Node {
        renormalized(canonical(node), w: 1, h: 1, x: 0, y: 0)
    }

    /// Convert a legacy absolute-cell tree (root extent ≫ 1) to unit
    /// fractions. Proportions are preserved; the old one-cell divider gaps
    /// are absorbed by the renormalize pass. Unit trees pass through.
    static func canonical(_ node: Node) -> Node {
        guard node.width > 1.5 || node.height > 1.5 else { return node }
        let sw = node.width > 0 ? 1.0 / node.width : 1
        let sh = node.height > 0 ? 1.0 / node.height : 1
        func scale(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                return .leaf(id: id, w: w * sw, h: h * sh, x: x * sw, y: y * sh)
            case .hsplit(let w, let h, let x, let y, let c):
                return .hsplit(w: w * sw, h: h * sh, x: x * sw, y: y * sh, children: c.map(scale))
            case .vsplit(let w, let h, let x, let y, let c):
                return .vsplit(w: w * sw, h: h * sh, x: x * sw, y: y * sh, children: c.map(scale))
            }
        }
        return renormalized(scale(node), w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Reading

    /// The pane ids of the leaves in depth-first order — the stable "pane
    /// order" every ordinal (⌘1-9, sidebar rows) addresses.
    public static func leafOrder(of node: Node) -> [String] {
        switch node {
        case .leaf(let id, _, _, _, _): return [id]
        case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
            return children.flatMap(leafOrder)
        }
    }

    /// Every leaf's fractional frame on the unit canvas, keyed by pane id.
    public static func fractions(of node: Node) -> [String: (w: Double, h: Double, x: Double, y: Double)] {
        var out: [String: (w: Double, h: Double, x: Double, y: Double)] = [:]
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                out[id] = (w, h, x, y)
            case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
                children.forEach(walk)
            }
        }
        walk(canonical(node))
        return out
    }

    // MARK: - Split (split a target pane's rect along an axis)

    /// Split `target`'s rect in two equal halves along the given axis and
    /// put `newID` in the second half (`newFirst` puts it in the first half
    /// instead — the "dock before" case). `horizontal` = side by side.
    /// Same-axis nesting is flattened into the parent container (canonical
    /// form). nil when `target` is missing or `newID` already used.
    public static func splitting(pane target: String, adding newID: String, horizontal: Bool,
                                 newFirst: Bool = false, in tree: Node) -> Node? {
        let node = canonical(tree)
        let ids = leafOrder(of: node)
        guard ids.contains(target), !ids.contains(newID) else { return nil }

        /// The freshly-created two-leaf container (target + new), and nothing
        /// else — the only shape same-axis flattening may dissolve.
        func isFreshSplit(_ n: Node) -> Bool {
            let children: [Node]
            switch (n, horizontal) {
            case (.hsplit(_, _, _, _, let c), true): children = c
            case (.vsplit(_, _, _, _, let c), false): children = c
            default: return false
            }
            guard children.count == 2 else { return false }
            let leafIDs = children.compactMap { child -> String? in
                if case .leaf(let id, _, _, _, _) = child { return id }
                return nil
            }
            return leafIDs.count == 2 && leafIDs.contains(newID) && leafIDs.contains(target)
        }

        func rebuild(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                guard id == target else { return n }
                if horizontal {
                    let half = w / 2
                    let a = Node.leaf(id: newFirst ? newID : id, w: half, h: h, x: x, y: y)
                    let b = Node.leaf(id: newFirst ? id : newID, w: half, h: h, x: x + half, y: y)
                    return .hsplit(w: w, h: h, x: x, y: y, children: [a, b])
                } else {
                    let half = h / 2
                    let a = Node.leaf(id: newFirst ? newID : id, w: w, h: half, x: x, y: y)
                    let b = Node.leaf(id: newFirst ? id : newID, w: w, h: half, x: x, y: y + half)
                    return .vsplit(w: w, h: h, x: x, y: y, children: [a, b])
                }
            case .hsplit(let w, let h, let x, let y, let children):
                var out: [Node] = []
                for child in children.map(rebuild) {
                    if horizontal, isFreshSplit(child),
                       case .hsplit(_, _, _, _, let grand) = child {
                        out.append(contentsOf: grand)   // flatten same-axis nesting
                    } else {
                        out.append(child)
                    }
                }
                return .hsplit(w: w, h: h, x: x, y: y, children: out)
            case .vsplit(let w, let h, let x, let y, let children):
                var out: [Node] = []
                for child in children.map(rebuild) {
                    if !horizontal, isFreshSplit(child),
                       case .vsplit(_, _, _, _, let grand) = child {
                        out.append(contentsOf: grand)
                    } else {
                        out.append(child)
                    }
                }
                return .vsplit(w: w, h: h, x: x, y: y, children: out)
            }
        }
        return renormalized(rebuild(node), w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Remove

    /// Remove a pane's leaf; its rect collapses into a sibling (the container
    /// renormalizes, so the space is shared proportionally — visually the
    /// neighbors absorb it). Returns nil when the pane isn't present or it
    /// was the only leaf.
    public static func removing(pane id: String, from tree: Node) -> Node? {
        let node = canonical(tree)
        guard let pruned = prune(id, node) else { return nil }
        return renormalized(pruned, w: 1, h: 1, x: 0, y: 0)
    }

    private static func prune(_ id: String, _ node: Node) -> Node? {
        switch node {
        case .leaf(let lid, _, _, _, _):
            return lid == id ? nil : node
        case .hsplit(let w, let h, let x, let y, let children):
            // No "unchanged" shortcut on child COUNT — a grandchild edit
            // doesn't change it. Always rebuild from the pruned children.
            let kept = children.compactMap { prune(id, $0) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }             // container dissolves
            return .hsplit(w: w, h: h, x: x, y: y, children: kept)
        case .vsplit(let w, let h, let x, let y, let children):
            let kept = children.compactMap { prune(id, $0) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return .vsplit(w: w, h: h, x: x, y: y, children: kept)
        }
    }

    // MARK: - Insert (new pane, no explicit target)

    /// Insert a new pane by splitting the largest leaf along its longer edge
    /// — where a person would put it to keep the arrangement balanced, and
    /// nobody else moves.
    public static func inserting(pane id: String, into tree: Node) -> Node {
        let node = canonical(tree)
        guard let target = largestLeaf(node),
              let split = splitting(pane: target, adding: id,
                                    horizontal: preferHorizontal(target, in: node),
                                    in: node) else { return node }
        return split
    }

    private static func largestLeaf(_ node: Node) -> String? {
        var best: (id: String, area: Double)?
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, _, _):
                let area = w * h
                if best == nil || area > best!.area { best = (id, area) }
            case .hsplit(_, _, _, _, let c), .vsplit(_, _, _, _, let c):
                c.forEach(walk)
            }
        }
        walk(node)
        return best?.id
    }

    /// "Longer edge" is judged on the legacy canvas aspect (160×48 ≈ a real
    /// window's shape), not the square unit canvas — this preserves the old
    /// column-first insertion pattern (a half-width pane still reads wider
    /// than full height).
    private static func preferHorizontal(_ id: String, in node: Node) -> Bool {
        guard let frame = fractions(of: node)[id] else { return true }
        return frame.w * Double(legacyCols) >= frame.h * Double(legacyRows)
    }

    // MARK: - Swap (content follows ids, geometry stays)

    /// Exchange two panes' positions. Geometry is untouched — only the ids
    /// trade places.
    public static func swapping(_ a: String, _ b: String, in tree: Node) -> Node {
        func rebuild(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                if id == a { return .leaf(id: b, w: w, h: h, x: x, y: y) }
                if id == b { return .leaf(id: a, w: w, h: h, x: x, y: y) }
                return n
            case .hsplit(let w, let h, let x, let y, let children):
                return .hsplit(w: w, h: h, x: x, y: y, children: children.map(rebuild))
            case .vsplit(let w, let h, let x, let y, let children):
                return .vsplit(w: w, h: h, x: x, y: y, children: children.map(rebuild))
            }
        }
        return rebuild(canonical(tree))
    }

    /// Reassign pane ids to the leaf SLOTS in a new depth-first order —
    /// geometry (each slot's rect) stays put; only which pane sits in each
    /// slot changes. `order` must be a permutation of the current leaf ids
    /// (any other input returns the tree unchanged). This is `swapping`
    /// generalized to a full permutation — how the sidebar's drag-reorder
    /// rewrites the pane order without disturbing the split arrangement.
    public static func reordering(to order: [String], in tree: Node) -> Node {
        let node = canonical(tree)
        let current = leafOrder(of: node)
        guard order.count == current.count, Set(order) == Set(current) else { return node }
        var queue = order
        func rebuild(_ n: Node) -> Node {
            switch n {
            case .leaf(_, let w, let h, let x, let y):
                return .leaf(id: queue.removeFirst(), w: w, h: h, x: x, y: y)
            case .hsplit(let w, let h, let x, let y, let c):
                return .hsplit(w: w, h: h, x: x, y: y, children: c.map(rebuild))
            case .vsplit(let w, let h, let x, let y, let c):
                return .vsplit(w: w, h: h, x: x, y: y, children: c.map(rebuild))
            }
        }
        return rebuild(node)
    }

    /// The pane before / after `id` in depth-first leaf order, wrapping.
    public static func neighbor(of id: String, previous: Bool, in node: Node) -> String? {
        let order = leafOrder(of: node)
        guard order.count > 1, let idx = order.firstIndex(of: id) else { return nil }
        let n = order.count
        return order[((idx + (previous ? -1 : 1)) % n + n) % n]
    }

    // MARK: - Dock (re-split target, move source into the half)

    /// Remove `source` from the tree and re-insert it by splitting `target`
    /// along `horizontal`, landing `before` or after — the VS Code edge-dock
    /// drop. nil when the move is impossible (same pane, missing ids, or
    /// source is the only pane).
    public static func docking(pane source: String, at target: String, horizontal: Bool,
                               before: Bool, in node: Node) -> Node? {
        guard source != target else { return nil }
        guard let without = removing(pane: source, from: node) else { return nil }
        guard leafOrder(of: without).contains(target) else { return nil }
        return splitting(pane: target, adding: source, horizontal: horizontal,
                         newFirst: before, in: without)
    }

    // MARK: - Tiled preset

    /// As square a grid as fits, rows filled top-down — the "even out
    /// everything" arrangement. `cols`/`rows` are ignored (legacy shim).
    public static func tiledPreset(panes: [String]) -> Node? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1 else {
            return .leaf(id: first, w: 1, h: 1, x: 0, y: 0)
        }
        let columns = Int(Double(panes.count).squareRoot().rounded(.up))
        let rowCount = Int((Double(panes.count) / Double(columns)).rounded(.up))
        var rowsNodes: [Node] = []
        var index = 0
        for _ in 0..<rowCount {
            let slice = panes[index..<min(index + columns, panes.count)]
            index += slice.count
            let leaves = slice.map { Node.leaf(id: $0, w: 1, h: 1, x: 0, y: 0) }
            if leaves.count == 1 {
                rowsNodes.append(leaves[0])
            } else {
                rowsNodes.append(.hsplit(w: 1, h: 1, x: 0, y: 0, children: leaves))
            }
        }
        let root: Node
        if rowsNodes.count == 1 {
            root = rowsNodes[0]
        } else {
            root = .vsplit(w: 1, h: 1, x: 0, y: 0, children: rowsNodes)
        }
        return renormalized(root, w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Renormalize

    /// Recompute every node's size and offset: distribute each container's
    /// extent to its children proportionally to their previous sizes,
    /// recursively. No divider space — dividers are a view concern now.
    static func renormalized(_ node: Node, w: Double, h: Double, x: Double, y: Double) -> Node {
        switch node {
        case .leaf(let id, _, _, _, _):
            return .leaf(id: id, w: w, h: h, x: x, y: y)
        case .hsplit(_, _, _, _, let children):
            let sizes = distribute(total: w, weights: children.map { max($0.width, .ulpOfOne) })
            var cx = x
            var out: [Node] = []
            for (child, cw) in zip(children, sizes) {
                out.append(renormalized(child, w: cw, h: h, x: cx, y: y))
                cx += cw
            }
            return .hsplit(w: w, h: h, x: x, y: y, children: out)
        case .vsplit(_, _, _, _, let children):
            let sizes = distribute(total: h, weights: children.map { max($0.height, .ulpOfOne) })
            var cy = y
            var out: [Node] = []
            for (child, ch) in zip(children, sizes) {
                out.append(renormalized(child, w: w, h: ch, x: x, y: cy))
                cy += ch
            }
            return .vsplit(w: w, h: h, x: x, y: y, children: out)
        }
    }

    /// Split `total` proportionally to `weights`; drift lands on the last
    /// part so the parts always sum to `total` exactly.
    static func distribute(total: Double, weights: [Double]) -> [Double] {
        let n = weights.count
        guard n > 0 else { return [] }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return Array(repeating: total / Double(n), count: n) }
        var out: [Double] = []
        var used = 0.0
        for (i, weight) in weights.enumerated() {
            if i == n - 1 {
                out.append(max(total - used, 0))
            } else {
                let share = total * weight / sum
                out.append(share)
                used += share
            }
        }
        return out
    }
}

