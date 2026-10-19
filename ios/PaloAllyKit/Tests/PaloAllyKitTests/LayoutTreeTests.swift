import Foundation
import Testing
@testable import PaloAllyKit

/// The tiling model (ported from Bento's LayoutTree tests, leaves are session
/// ids), the host's JSON, dividers, reconciling, and the narrow policy.
@Suite("Layout tree")
struct LayoutTreeTests {
    typealias T = LayoutTree
    private func f(_ n: T.Node) -> [String: (w: Double, h: Double, x: Double, y: Double)] { T.fractions(of: n) }
    private func close(_ a: Double, _ b: Double, _ e: Double = 1e-9) -> Bool { abs(a - b) <= e }

    /// The sample in docs/workbench-rpc.md.
    static let hostSample = """
    {"type":"hsplit","w":1,"h":1,"x":0,"y":0,"children":[
      {"type":"leaf","session":"pal_3f9a1c0b2d4e","w":0.5,"h":1,"x":0,"y":0},
      {"type":"vsplit","w":0.5,"h":1,"x":0.5,"y":0,"children":[
        {"type":"leaf","session":"pal_55e0c4a1b2d3","w":0.5,"h":0.5,"x":0.5,"y":0},
        {"type":"leaf","session":"pal_77aa00bb11cc","w":0.5,"h":0.5,"x":0.5,"y":0.5}]}]}
    """

    private func row3() -> T.Node {
        var t = T.single(pane: "a")
        t = T.splitting(pane: "a", adding: "b", horizontal: true, in: t)!
        return T.splitting(pane: "b", adding: "c", horizontal: true, in: t)!
    }

    // MARK: JSON

    @Test func hostSampleRoundTrips() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(Self.hostSample.utf8))
        let node = try #require(T.Node(json: json))
        #expect(T.leafOrder(of: node) == ["pal_3f9a1c0b2d4e", "pal_55e0c4a1b2d3", "pal_77aa00bb11cc"])
        #expect(node.json == json)
        let again = try JSONDecoder().decode(T.Node.self, from: JSONEncoder().encode(node))
        #expect(again == node)
        // The encoding is the host's shape: `session` on leaves, no `id`.
        let text = String(data: try JSONEncoder().encode(node), encoding: .utf8)!
        #expect(text.contains("\"session\"") && !text.contains("\"id\""))
    }

    @Test func badJSONIsNil() {
        #expect(T.Node(json: nil) == nil)
        #expect(T.Node(json: .null) == nil)
        #expect(T.Node(json: .object(["type": .string("leaf"), "w": .number(1)])) == nil)
    }

    // MARK: structure

    @Test func singleFillsTheCanvas() {
        let r = f(T.single(pane: "a"))["a"]!
        #expect(close(r.w, 1) && close(r.h, 1) && close(r.x, 0))
    }

    @Test func splitHalvesExactly() {
        let s = T.splitting(pane: "a", adding: "b", horizontal: true, in: T.single(pane: "a"))!
        let r = f(s)
        #expect(close(r["a"]!.w, 0.5) && close(r["b"]!.w, 0.5) && close(r["b"]!.x, 0.5))
        #expect(T.splitting(pane: "a", adding: "a", horizontal: true, in: s) == nil)
        #expect(T.splitting(pane: "zz", adding: "q", horizontal: true, in: s) == nil)
    }

    @Test func sameAxisSplitsFlatten() {
        #expect(f(row3()).values.allSatisfy { close($0.w, 0.25) || close($0.w, 0.5) })
        let t = T.splitting(pane: "c", adding: "d", horizontal: true, in: row3())!
        if case .hsplit(_, _, _, _, let c) = t { #expect(c.count == 4) } else { Issue.record("not an hsplit") }
    }

    @Test func closeSharesTheSpace() {
        let pruned = T.removing(pane: "b", from: row3())!
        let r = f(pruned)
        #expect(r["b"] == nil)
        #expect(close(r["a"]!.w + r["c"]!.w, 1))
        #expect(close(r["a"]!.w / r["c"]!.w, 2, 0.01))
        #expect(T.removing(pane: "a", from: T.single(pane: "a")) == nil)
    }

    @Test func closingDownToOneDissolvesTheSplit() {
        let s = T.splitting(pane: "a", adding: "b", horizontal: false, in: T.single(pane: "a"))!
        #expect(T.removing(pane: "b", from: s) == .leaf(id: "a", w: 1, h: 1, x: 0, y: 0))
    }

    @Test func swapKeepsGeometry() {
        let t = row3()
        let s = T.swapping("a", "c", in: t)
        #expect(T.leafOrder(of: s) == ["c", "b", "a"])
        #expect(close(f(s)["c"]!.x, f(t)["a"]!.x))
    }

    @Test func reorderingRejectsNonPermutations() {
        let t = row3()
        #expect(T.leafOrder(of: T.reordering(to: ["c", "a", "b"], in: t)) == ["c", "a", "b"])
        #expect(T.leafOrder(of: T.reordering(to: ["a", "x", "c"], in: t)) == ["a", "b", "c"])
        #expect(T.leafOrder(of: T.reordering(to: ["a"], in: t)) == ["a", "b", "c"])
    }

    @Test func dockEveryEdge() throws {
        let t = T.splitting(pane: "a", adding: "b", horizontal: true, in: T.single(pane: "a"))!
        // c docks to the top of b: b's column splits into c over b.
        for (zone, horizontal, before) in [(PaneDropZone.top, false, true), (.bottom, false, false),
                                           (.left, true, true), (.right, true, false)] {
            let d = try #require(zone.dock)
            #expect(d.horizontal == horizontal && d.before == before)
            var base = T.splitting(pane: "b", adding: "c", horizontal: true, in: t)!
            base = try #require(T.docking(pane: "c", at: "b", horizontal: d.horizontal, before: d.before, in: base))
            let r = f(base)
            #expect(Set(r.keys) == ["a", "b", "c"])
            let (b, c) = (r["b"]!, r["c"]!)
            switch zone {
            case .top: #expect(c.y < b.y && close(c.x, b.x))
            case .bottom: #expect(c.y > b.y && close(c.x, b.x))
            case .left: #expect(c.x < b.x && close(c.y, b.y))
            default: #expect(c.x > b.x && close(c.y, b.y))
            }
            #expect(close(r.values.map { $0.w * $0.h }.reduce(0, +), 1))
        }
        #expect(T.docking(pane: "a", at: "a", horizontal: true, before: true, in: t) == nil)
        #expect(T.docking(pane: "a", at: "zz", horizontal: true, before: true, in: t) == nil)
    }

    @Test func dropZones() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PaneDropZone.zone(at: CGPoint(x: 50, y: 50), in: r) == .center)
        #expect(PaneDropZone.zone(at: CGPoint(x: 5, y: 50), in: r) == .left)
        #expect(PaneDropZone.zone(at: CGPoint(x: 95, y: 50), in: r) == .right)
        #expect(PaneDropZone.zone(at: CGPoint(x: 50, y: 5), in: r) == .top)
        #expect(PaneDropZone.zone(at: CGPoint(x: 50, y: 95), in: r) == .bottom)
        #expect(PaneDropZone.left.highlightRect(in: r) == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(PaneDropZone.bottom.highlightRect(in: r) == CGRect(x: 0, y: 50, width: 100, height: 50))
    }

    @Test func tiledPresetEvensOut() {
        let r = f(T.tiledPreset(panes: ["a", "b", "c", "d"])!)
        for id in ["a", "b", "c", "d"] { #expect(close(r[id]!.w, 0.5) && close(r[id]!.h, 0.5)) }
        #expect(T.tiledPreset(panes: []) == nil)
    }

    @Test func normalizeFixesDrift() {
        // Children that don't fill the parent are scaled to fill it.
        let skewed = T.Node.hsplit(w: 1, h: 1, x: 0, y: 0, children: [
            .leaf(id: "a", w: 0.2, h: 1, x: 0, y: 0), .leaf(id: "b", w: 0.2, h: 1, x: 0.7, y: 0)])
        let r = f(T.resized(skewed))
        #expect(close(r["a"]!.w, 0.5) && close(r["b"]!.w, 0.5) && close(r["b"]!.x, 0.5))
    }

    // MARK: dividers

    @Test func dividersOfTheHostSample() throws {
        let node = try JSONDecoder().decode(T.Node.self, from: Data(Self.hostSample.utf8))
        let d = T.dividers(of: node)
        #expect(d.count == 2)
        let v = try #require(d.first { $0.vertical })
        #expect(close(v.position, 0.5) && v.path == [] && v.index == 0 && v.span == 0...1)
        let h = try #require(d.first { !$0.vertical })
        #expect(close(h.position, 0.5) && h.path == [1] && close(h.span.lowerBound, 0.5))
        #expect(Set(d.map(\.id)).count == 2)
    }

    @Test func resizeMovesTheBorder() {
        let s = T.splitting(pane: "a", adding: "b", horizontal: true, in: T.single(pane: "a"))!
        let r = f(T.movingDivider(path: [], index: 0, by: 0.1, in: s))
        #expect(close(r["a"]!.w, 0.6) && close(r["b"]!.w, 0.4) && close(r["b"]!.x, 0.6))
        let back = f(T.movingDivider(path: [], index: 0, by: -0.2, in: s))
        #expect(close(back["a"]!.w, 0.3))
    }

    @Test func resizeClampsAtTheMinimum() {
        let s = T.splitting(pane: "a", adding: "b", horizontal: true, in: T.single(pane: "a"))!
        let r = f(T.movingDivider(path: [], index: 0, by: 5, in: s))
        #expect(close(r["b"]!.w, T.minShare) && close(r["a"]!.w, 1 - T.minShare))
        let l = f(T.movingDivider(path: [], index: 0, by: -5, minShare: 0.15, in: s))
        #expect(close(l["a"]!.w, 0.15))
    }

    @Test func resizeInANestedSplitScalesItsChildren() throws {
        let node = try JSONDecoder().decode(T.Node.self, from: Data(Self.hostSample.utf8))
        let r = f(T.movingDivider(path: [1], index: 0, by: 0.25, in: node))
        #expect(close(r["pal_55e0c4a1b2d3"]!.h, 0.75) && close(r["pal_77aa00bb11cc"]!.h, 0.25))
        #expect(close(r["pal_3f9a1c0b2d4e"]!.w, 0.5))
        // A wrong path changes nothing.
        #expect(T.movingDivider(path: [9], index: 0, by: 0.1, in: node) == T.canonical(node))
        #expect(T.movingDivider(path: [], index: 5, by: 0.1, in: node) == T.canonical(node))
    }

    // MARK: members and focus

    @Test func reconcileDropsStrangersAndAddsNewMembers() {
        let t = row3()
        let r = T.reconciled(t, members: ["a", "c", "d"])!
        #expect(Set(T.leafOrder(of: r)) == ["a", "c", "d"])
        #expect(close(f(r).values.map { $0.w * $0.h }.reduce(0, +), 1))
        #expect(T.reconciled(nil, members: ["a", "b", "c"]).map(T.leafOrder(of:)) == ["a", "b", "c"])
        #expect(T.reconciled(t, members: []) == nil)
        #expect(T.reconciled(t, members: ["a", "b", "c"]) == t)
    }

    @Test func reconcileMergesRepeats() {
        let dup = T.Node.hsplit(w: 1, h: 1, x: 0, y: 0, children: [
            .leaf(id: "a", w: 0.5, h: 1, x: 0, y: 0), .leaf(id: "a", w: 0.5, h: 1, x: 0.5, y: 0)])
        #expect(T.reconciled(dup, members: ["a"]).map(T.leafOrder(of:)) == ["a"])
        #expect(T.reconciled(dup, members: ["a", "b"]).map { Set(T.leafOrder(of: $0)) } == ["a", "b"])
    }

    @Test func focusNextPreviousAndAfterClosing() {
        let t = row3()
        #expect(T.neighbor(of: "c", previous: false, in: t) == "a")
        #expect(T.neighbor(of: "a", previous: true, in: t) == "c")
        #expect(T.neighbor(of: "a", previous: true, in: T.single(pane: "a")) == nil)
        #expect(T.focusAfterClosing("b", in: t) == "c")
        #expect(T.focusAfterClosing("c", in: t) == "b")
        #expect(T.focusAfterClosing("a", in: T.single(pane: "a")) == nil)
    }

    // MARK: narrow

    @Test func narrowShowsTwoAndListsTheRest() {
        let order = ["a", "b", "c", "d", "e"]
        let wide = T.narrowPolicy(order: order, active: "c", width: 1000)
        #expect(wide.visible == order && wide.switcher.isEmpty && !wide.isNarrow)
        let n = T.narrowPolicy(order: order, active: "c", width: 500)
        #expect(n.visible == ["c", "d"] && n.switcher == ["a", "b", "e"] && n.isNarrow)
        let last = T.narrowPolicy(order: order, active: "e", width: 500)
        #expect(last.visible == ["d", "e"])
        let none = T.narrowPolicy(order: order, active: nil, width: 500)
        #expect(none.visible == ["a", "b"])
        let few = T.narrowPolicy(order: ["a", "b"], active: "a", width: 300)
        #expect(few.visible == ["a", "b"] && few.switcher.isEmpty)
        #expect(T.narrowPolicy(order: order, active: "a", width: 500, maxVisible: 1).visible == ["a"])
    }

    @Test func keepingTrimsForDisplay() {
        let t = row3()
        let k = T.keeping(["a", "c"], in: t)!
        #expect(T.leafOrder(of: k) == ["a", "c"])
        #expect(close(f(k)["a"]!.w + f(k)["c"]!.w, 1))
        #expect(T.keeping([], in: t) == nil)
    }
}
