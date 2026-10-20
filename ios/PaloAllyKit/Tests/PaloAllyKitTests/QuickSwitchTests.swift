import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Quick switch")
struct QuickSwitchTests {
    private func pal(_ id: String, at: Int64, ws: String? = nil, folded: Bool = false) -> Pal {
        Pal(id: id, name: id, cwd: "/tmp/\(id)", sessionId: "s-\(id)", status: .idle, updatedAt: at, workspaceId: ws, folded: folded)
    }

    @Test func inAWorkspaceTheStripIsItsMembersInOrder() {
        let pals = [pal("a", at: 1, ws: "w"), pal("b", at: 3, ws: "w"), pal("x", at: 9)]
        let ws = [Workspace(id: "w", memberIds: ["b", "a"])]
        #expect(QuickSwitch.members(current: "a", pals: pals, workspaces: ws) == ["b", "a"])
    }

    @Test func outsideAWorkspaceThereIsNoStrip() {
        let pals = [pal("a", at: 1), pal("b", at: 3), pal("m", at: 5, ws: "w"), pal("n", at: 6, ws: "w")]
        let ws = [Workspace(id: "w", memberIds: ["m", "n"])]
        #expect(QuickSwitch.members(current: "a", pals: pals, workspaces: ws).isEmpty)
        #expect(QuickSwitch.members(current: "nobody", pals: pals, workspaces: ws).isEmpty)
    }

    @Test func aWorkspaceOfOneHasNoStrip() {
        let pals = [pal("a", at: 1, ws: "w"), pal("b", at: 3)]
        #expect(QuickSwitch.members(current: "a", pals: pals, workspaces: [Workspace(id: "w", memberIds: ["a"])]).isEmpty)
    }

    @Test func swipesStopAtTheEnds() {
        let m = ["a", "b", "c"]
        #expect(QuickSwitch.neighbor(of: "b", step: 1, in: m) == "c")
        #expect(QuickSwitch.neighbor(of: "b", step: -1, in: m) == "a")
        #expect(QuickSwitch.neighbor(of: "a", step: -1, in: m) == nil)
        #expect(QuickSwitch.neighbor(of: "c", step: 1, in: m) == nil)
        #expect(QuickSwitch.neighbor(of: "zz", step: 1, in: m) == nil)
    }

    @Test func endingLandsOnTheLeftNeighborElseTheRight() {
        #expect(QuickSwitch.landing(after: "c", in: ["a", "b", "c"]) == "b")
        #expect(QuickSwitch.landing(after: "a", in: ["a", "b"]) == "b")
        #expect(QuickSwitch.landing(after: "a", in: ["a"]) == nil)
    }
}
