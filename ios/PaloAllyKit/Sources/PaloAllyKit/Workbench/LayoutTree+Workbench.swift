import Foundation

// What the workbench adds to the ported tree: the host's JSON, dividers that
// can be dragged, reconciling with a workspace's members, focus, and the
// narrow-width policy.

// MARK: - the host's JSON (docs/workbench-rpc.md, "LayoutNode")

extension LayoutTree.Node: Codable {
    private enum CodingKeys: String, CodingKey { case type, session, w, h, x, y, children }
    private enum Kind: String, Codable { case leaf, hsplit, vsplit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        let w = try c.decode(Double.self, forKey: .w)
        let h = try c.decode(Double.self, forKey: .h)
        let x = try c.decode(Double.self, forKey: .x)
        let y = try c.decode(Double.self, forKey: .y)
        switch kind {
        case .leaf:
            self = .leaf(id: try c.decode(String.self, forKey: .session), w: w, h: h, x: x, y: y)
        case .hsplit:
            self = .hsplit(w: w, h: h, x: x, y: y, children: try c.decode([LayoutTree.Node].self, forKey: .children))
        case .vsplit:
            self = .vsplit(w: w, h: h, x: x, y: y, children: try c.decode([LayoutTree.Node].self, forKey: .children))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id, let w, let h, let x, let y):
            try c.encode(Kind.leaf, forKey: .type)
            try c.encode(id, forKey: .session)
            try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case .hsplit(let w, let h, let x, let y, let children):
            try c.encode(Kind.hsplit, forKey: .type)
            try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(children, forKey: .children)
        case .vsplit(let w, let h, let x, let y, let children):
            try c.encode(Kind.vsplit, forKey: .type)
            try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(children, forKey: .children)
        }
    }

    /// The tree as `Workspace.layout` holds it.
    public var json: JSONValue? { try? JSONValue.from(self) }

    /// Reads `Workspace.layout`; nil when absent or not a tree.
    public init?(json: JSONValue?) {
        guard let json, json != .null, let n = try? json.decode(LayoutTree.Node.self) else { return nil }
        self = n
    }
}

extension LayoutTree {
    // MARK: - Dividers

    /// A boundary between two neighbours inside one split: a thin line to drag.
    public struct Divider: Equatable, Sendable, Identifiable {
        /// Child indices from the root to the split that owns this boundary.
        public var path: [Int]
        /// The boundary sits after this child (between `index` and `index + 1`).
        public var index: Int
        /// true = a vertical line (the split is `hsplit`, children side by side).
        public var vertical: Bool
        /// Where the line is on the unit canvas (x if vertical, else y).
        public var position: Double
        /// The line's extent on the other axis (from, to), unit canvas.
        public var span: ClosedRange<Double>
        public var id: String { "\(path.map(String.init).joined(separator: "."))|\(index)" }
    }

    /// Every divider of a (normalized) tree.
    public static func dividers(of tree: Node) -> [Divider] {
        var out: [Divider] = []
        func walk(_ n: Node, _ path: [Int]) {
            switch n {
            case .leaf: return
            case .hsplit(_, let h, _, let y, let c):
                for i in 0..<max(c.count - 1, 0) {
                    out.append(Divider(path: path, index: i, vertical: true, position: c[i].xOrigin + c[i].width,
                                       span: y...(y + h)))
                }
                for (i, k) in c.enumerated() { walk(k, path + [i]) }
            case .vsplit(let w, _, let x, _, let c):
                for i in 0..<max(c.count - 1, 0) {
                    out.append(Divider(path: path, index: i, vertical: false, position: c[i].yOrigin + c[i].height,
                                       span: x...(x + w)))
                }
                for (i, k) in c.enumerated() { walk(k, path + [i]) }
            }
        }
        walk(tree, [])
        return out
    }

    /// Move a divider by `delta` (a fraction of the whole canvas along its axis;
    /// positive = right or down). The two neighbours trade the space and neither
    /// goes under `minShare` of the canvas. Unchanged when the path is wrong.
    public static func movingDivider(path: [Int], index: Int, by delta: Double, minShare: Double = LayoutTree.minShare,
                                     in tree: Node) -> Node {
        let node = canonical(tree)
        func edit(_ n: Node, _ rest: ArraySlice<Int>) -> Node? {
            if let head = rest.first {
                switch n {
                case .leaf: return nil
                case .hsplit(let w, let h, let x, let y, var c):
                    guard c.indices.contains(head), let r = edit(c[head], rest.dropFirst()) else { return nil }
                    c[head] = r
                    return .hsplit(w: w, h: h, x: x, y: y, children: c)
                case .vsplit(let w, let h, let x, let y, var c):
                    guard c.indices.contains(head), let r = edit(c[head], rest.dropFirst()) else { return nil }
                    c[head] = r
                    return .vsplit(w: w, h: h, x: x, y: y, children: c)
                }
            }
            switch n {
            case .leaf: return nil
            case .hsplit(let w, let h, let x, let y, var c):
                guard c.indices.contains(index), c.indices.contains(index + 1) else { return nil }
                let (a, b) = (c[index].width, c[index + 1].width)
                let d = max(min(delta, b - minShare), minShare - a)
                c[index] = c[index].withWidth(a + d)
                c[index + 1] = c[index + 1].withWidth(b - d)
                return .hsplit(w: w, h: h, x: x, y: y, children: c)
            case .vsplit(let w, let h, let x, let y, var c):
                guard c.indices.contains(index), c.indices.contains(index + 1) else { return nil }
                let (a, b) = (c[index].height, c[index + 1].height)
                let d = max(min(delta, b - minShare), minShare - a)
                c[index] = c[index].withHeight(a + d)
                c[index + 1] = c[index + 1].withHeight(b - d)
                return .vsplit(w: w, h: h, x: x, y: y, children: c)
            }
        }
        guard let edited = edit(node, path[...]) else { return node }
        return renormalized(edited, w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Reconcile with the members

    /// The tree a workspace should show: only its members (extra leaves and
    /// repeats go), members the tree lacks added by `inserting`, then
    /// renormalized. No tree at all: the even grid. Nil when there are no members.
    public static func reconciled(_ tree: Node?, members: [String]) -> Node? {
        guard !members.isEmpty else { return nil }
        guard var node = tree.map(canonical) else { return tiledPreset(panes: members) }
        let keep = Set(members)
        let order = leafOrder(of: node)
        let extra = Set(order.filter { !keep.contains($0) })
        let repeated = Set(Dictionary(grouping: order, by: { $0 }).filter { $0.value.count > 1 }.keys).intersection(keep)
        for id in extra.union(repeated) {
            guard let r = removing(pane: id, from: node) else { return tiledPreset(panes: members) }
            node = r
        }
        for id in members where !leafOrder(of: node).contains(id) { node = inserting(pane: id, into: node) }
        return renormalized(node, w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Focus

    /// Who is active once `id` is closed: the neighbour after it, else before.
    public static func focusAfterClosing(_ id: String, in tree: Node) -> String? {
        let order = leafOrder(of: tree)
        guard let i = order.firstIndex(of: id), order.count > 1 else { return nil }
        return i + 1 < order.count ? order[i + 1] : order[i - 1]
    }

    // MARK: - Narrow widths (iPad slide over, split view)

    /// What a narrow window shows: at most `maxVisible` tiles, the rest in a switcher.
    public struct NarrowTiling: Equatable, Sendable {
        /// The tiles to lay out, in leaf order.
        public var visible: [String]
        /// The others, in leaf order, for the switcher.
        public var switcher: [String]
        public var isNarrow: Bool { !switcher.isEmpty }
    }

    /// Below `narrowBelow` points wide, show the active tile and the one next to
    /// it (the one after, else the one before); a wider window shows them all.
    public static func narrowPolicy(order: [String], active: String?, width: Double,
                                    narrowBelow: Double = 700, maxVisible: Int = 2) -> NarrowTiling {
        guard width < narrowBelow, order.count > maxVisible, maxVisible > 0 else {
            return NarrowTiling(visible: order, switcher: [])
        }
        let anchor = active.flatMap { order.firstIndex(of: $0) } ?? 0
        var picked: [Int] = [anchor]
        var after = anchor + 1, before = anchor - 1
        while picked.count < maxVisible {
            if after < order.count { picked.append(after); after += 1 }
            else if before >= 0 { picked.append(before); before -= 1 }
            else { break }
        }
        let set = Set(picked)
        return NarrowTiling(visible: order.indices.filter(set.contains).map { order[$0] },
                            switcher: order.indices.filter { !set.contains($0) }.map { order[$0] })
    }

    /// The tree reduced to some of its leaves (display only; the stored tree
    /// keeps the rest). Nil when none is left.
    public static func keeping(_ ids: [String], in tree: Node) -> Node? {
        var node = canonical(tree)
        let keep = Set(ids)
        for id in leafOrder(of: node) where !keep.contains(id) {
            guard let r = removing(pane: id, from: node) else { return nil }
            node = r
        }
        return node
    }
}

extension LayoutTree.Node {
    var xOrigin: Double {
        switch self { case .leaf(_, _, _, let x, _), .hsplit(_, _, let x, _, _), .vsplit(_, _, let x, _, _): return x }
    }
    var yOrigin: Double {
        switch self { case .leaf(_, _, _, _, let y), .hsplit(_, _, _, let y, _), .vsplit(_, _, _, let y, _): return y }
    }
    func withWidth(_ e: Double) -> LayoutTree.Node {
        switch self {
        case .leaf(let id, _, let h, let x, let y): return .leaf(id: id, w: e, h: h, x: x, y: y)
        case .hsplit(_, let h, let x, let y, let c): return .hsplit(w: e, h: h, x: x, y: y, children: c)
        case .vsplit(_, let h, let x, let y, let c): return .vsplit(w: e, h: h, x: x, y: y, children: c)
        }
    }
    func withHeight(_ e: Double) -> LayoutTree.Node {
        switch self {
        case .leaf(let id, let w, _, let x, let y): return .leaf(id: id, w: w, h: e, x: x, y: y)
        case .hsplit(let w, _, let x, let y, let c): return .hsplit(w: w, h: e, x: x, y: y, children: c)
        case .vsplit(let w, _, let x, let y, let c): return .vsplit(w: w, h: e, x: x, y: y, children: c)
        }
    }
}
