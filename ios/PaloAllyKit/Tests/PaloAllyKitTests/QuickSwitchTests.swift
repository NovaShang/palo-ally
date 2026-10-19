import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Quick switch")
struct QuickSwitchTests {
    private func pal(_ id: String, at: Int64, ws: String? = nil, folded: Bool = false) -> Pal {
        Pal(id: id, name: id, cwd: "/tmp/\(id)", sessionId: "s-\(id)", status: .idle, updatedAt: at, workspaceId: ws, folded: folded)
    }

    @Test func outsideAWorkspaceTheStripIsPaloThenUnfoldedSessionsInSidebarOrder() {
        let pals = [pal("a", at: 1), pal("b", at: 3), pal("c", at: 2), pal("old", at: 9, folded: true), pal("m", at: 5, ws: "w")]
        let ws = [Workspace(id: "w", memberIds: ["m"])]
        #expect(QuickSwitch.members(current: .palo, pals: pals, workspaces: ws)
                == [.palo, .session("b"), .session("c"), .session("a")])
        #expect(QuickSwitch.members(current: .session("c"), pals: pals, workspaces: ws)
                == [.palo, .session("b"), .session("c"), .session("a")])
    }

    @Test func inAWorkspaceTheStripIsItsMembersInOrder() {
        let pals = [pal("a", at: 1, ws: "w"), pal("b", at: 3, ws: "w"), pal("x", at: 9)]
        let ws = [Workspace(id: "w", memberIds: ["b", "a"])]
        #expect(QuickSwitch.members(current: .session("a"), pals: pals, workspaces: ws) == [.session("b"), .session("a")])
    }

    @Test func aFoldedCurrentSessionStillHasItsChip() {
        let pals = [pal("a", at: 1), pal("old", at: 9, folded: true)]
        #expect(QuickSwitch.members(current: .session("old"), pals: pals, workspaces: [])
                == [.palo, .session("a"), .session("old")])
    }

    @Test func swipesStopAtTheEnds() {
        let m: [QuickSwitch.Member] = [.palo, .session("a"), .session("b")]
        #expect(QuickSwitch.neighbor(of: .session("a"), step: 1, in: m) == .session("b"))
        #expect(QuickSwitch.neighbor(of: .session("a"), step: -1, in: m) == .palo)
        #expect(QuickSwitch.neighbor(of: .palo, step: -1, in: m) == nil)
        #expect(QuickSwitch.neighbor(of: .session("b"), step: 1, in: m) == nil)
        #expect(QuickSwitch.neighbor(of: .session("zz"), step: 1, in: m) == nil)
    }

    @Test func endingLandsOnTheLeftNeighborElsePalo() {
        let m: [QuickSwitch.Member] = [.palo, .session("a"), .session("b")]
        #expect(QuickSwitch.landing(after: .session("b"), in: m) == .session("a"))
        let w: [QuickSwitch.Member] = [.session("a"), .session("b")]
        #expect(QuickSwitch.landing(after: .session("a"), in: w) == .session("b"))
        #expect(QuickSwitch.landing(after: .session("a"), in: [.session("a")]) == .palo)
    }
}
