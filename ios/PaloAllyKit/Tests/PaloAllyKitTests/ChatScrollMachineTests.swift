import CoreGraphics
import Testing
@testable import PaloAllyKit

/// One test per row of the transition table (design §3.5), plus the edges
/// the scroll lab and the stress demo found (design §8).
@Suite("Chat scroll machine")
struct ChatScrollMachineTests {
    typealias M = ChatScrollMachine

    /// A machine in `mode`, `distance` from the end, idle.
    func machine(_ mode: M.Mode, distance: CGFloat = 0) -> M {
        var m = M()
        switch mode {
        case .following: break
        case .detached:
            _ = m.reduce(.reveal(id: "m1"))
        case .returning:
            _ = m.reduce(.reveal(id: "m1"))
            _ = m.reduce(.jump(viewingPast: false, screens: 1))
        }
        _ = m.reduce(.scrolled(distance: distance))
        #expect(m.mode == mode)
        return m
    }

    /// A finger comes down and drags `by` points (positive: down the screen,
    /// toward older messages), in a few steps.
    func drag(_ m: inout M, by total: CGFloat, steps: Int = 4) -> [M.Effect] {
        var fx = m.reduce(.phase(.interacting))
        for i in 1...steps { fx += m.reduce(.finger(total * CGFloat(i) / CGFloat(steps))) }
        return fx
    }

    // MARK: following

    @Test func followingDragTowardOlderLetsGo() {
        var m = machine(.following)
        let fx = drag(&m, by: 12)
        #expect(m.mode == .detached)
        #expect(fx == [.log("following → detached (drag)"), .holdTopRow(true)])
    }

    @Test func followingFlingTowardOlderLetsGo() {
        var m = machine(.following)
        _ = m.reduce(.phase(.interacting))
        _ = m.reduce(.finger(5))
        let fx = m.reduce(.lifted(velocity: 2400))
        _ = m.reduce(.phase(.decelerating))
        #expect(m.mode == .detached)
        #expect(fx.first == .log("following → detached (fling)"))
    }

    @Test func aFlingThatSeemsToStayOnTheEndStillLetsGo() {
        // Crossing the lazy history, the reported height falls as fast as
        // the offset: the distance reads 0 all the way. The finger decides.
        var m = machine(.following)
        _ = m.reduce(.phase(.interacting))
        for _ in 0..<4 { _ = m.reduce(.scrolled(distance: 0)) }
        _ = m.reduce(.finger(30))
        #expect(m.mode == .detached)
    }

    @Test func followingRestingFingerDoesNothing() {
        var m = machine(.following)
        var fx = m.reduce(.phase(.tracking))
        // A reply grows under the finger, or the layout throws the view: the
        // end moves away, the finger doesn't.
        fx += m.reduce(.scrolled(distance: 40))
        fx += m.reduce(.finger(0))
        fx += m.reduce(.phase(.interacting))
        fx += m.reduce(.scrolled(distance: 1793))
        fx += m.reduce(.finger(0.5))
        #expect(m.mode == .following)
        #expect(fx == [])
        // Lifted off the end: back onto it, no letting go.
        #expect(m.reduce(.lifted(velocity: 0)) == [])
        // Thrown far: back at once, not on a long animated trip.
        #expect(m.reduce(.phase(.idle)) == [.toEnd(animated: false)])
        #expect(m.mode == .following)
    }

    @Test func followingShortDragThenLiftGoesBackOntoTheEnd() {
        var m = machine(.following)
        var fx = drag(&m, by: 5)
        fx += m.reduce(.scrolled(distance: 5))
        fx += m.reduce(.lifted(velocity: 40))
        fx += m.reduce(.phase(.idle))
        #expect(m.mode == .following)
        #expect(fx == [.toEnd(animated: true)])
    }

    @Test func dragAndFlingTowardNewerDontLetGo() {
        // At the end, a drag up (finger moving up) stretches past it and springs back.
        var m = machine(.following)
        _ = drag(&m, by: -40)
        _ = m.reduce(.lifted(velocity: -1800))
        #expect(m.reduce(.phase(.idle)) == [])
        #expect(m.mode == .following)
    }

    @Test func followingContentGrowsNothingToDo() {
        var m = machine(.following)
        // The system's bottom anchor keeps the end in view; no scrolling, no dot.
        #expect(m.reduce(.grewBelow) == [])
        #expect(m.mode == .following)
        #expect(!m.unseenBelow)
    }

    @Test func followingKeyboardKeepsTheEndAboveIt() {
        var m = machine(.following)
        // The keyboard covered the end.
        _ = m.reduce(.scrolled(distance: 30))
        #expect(m.reduce(.bottomInsetGrew) == [.toEnd(animated: true)])
        #expect(m.mode == .following)
        // Nothing covered: nothing to do.
        var n = machine(.following)
        #expect(n.reduce(.bottomInsetGrew) == [])
    }

    @Test func followingWidthChangeKeepsTheEnd() {
        var m = machine(.following)
        #expect(m.reduce(.layoutChanged) == [])
        // Slipped off the end in the rewrap: straight back.
        _ = m.reduce(.scrolled(distance: 40))
        #expect(m.reduce(.layoutChanged) == [.toEnd(animated: false)])
        #expect(m.mode == .following)
    }

    @Test func followingThrownOffTheEndByLayoutGoesBack() {
        var m = machine(.following)
        let fx = m.reduce(.scrolled(distance: 12_900))
        #expect(fx == [.log("following: thrown off the end by layout"), .toEnd(animated: false)])
        #expect(m.mode == .following)
        // Growth inside an animation lags the end a few points: not thrown.
        var n = machine(.following)
        #expect(n.reduce(.scrolled(distance: 22)) == [])
        // Under the reader's finger the layout is left alone.
        var o = machine(.following)
        _ = o.reduce(.phase(.interacting))
        #expect(o.reduce(.scrolled(distance: 2000)) == [])
    }

    @Test func followingScrollToTheEndThatStopsShortGoesTheRestAtOnce() {
        var m = machine(.following)
        _ = m.reduce(.phase(.animating))
        _ = m.reduce(.scrolled(distance: 17_186))
        #expect(m.reduce(.phase(.idle)) == [.log("following: a scroll to the end stopped short"), .toEnd(animated: false)])
        // On the end: nothing.
        var n = machine(.following)
        _ = n.reduce(.phase(.animating))
        #expect(n.reduce(.phase(.idle)) == [])
    }

    // MARK: any → send

    @Test(arguments: [M.Mode.following, .detached, .returning])
    func sendingAlwaysGoesToTheEnd(_ mode: M.Mode) {
        var m = machine(mode, distance: 3000)
        let fx = m.reduce(.sent)
        #expect(m.mode == .following)
        #expect(fx.last == .toEnd(animated: true))
        if mode != .following {
            #expect(fx.contains(.holdTopRow(false)))
        }
    }

    // MARK: detached

    @Test func detachedGrowthOrCatchUpMovesNothingButMarksTheButton() {
        var m = machine(.detached, distance: 4000)
        #expect(m.reduce(.grewBelow) == [])
        #expect(m.unseenBelow)
        #expect(m.mode == .detached)
        #expect(m.showsJump)
    }

    @Test func detachedWidthChangeOrInsertAboveKeepsTheTopRow() {
        // The top row is held (holdTopRow from detaching); the machine itself
        // scrolls nothing.
        var m = machine(.detached, distance: 4000)
        #expect(m.reduce(.layoutChanged) == [])
        #expect(m.reduce(.scrolled(distance: 4300)) == [])
        #expect(m.mode == .detached)
    }

    @Test func detachedScrollEndingNearTheEndFollowsAgain() {
        var m = machine(.detached, distance: 300)
        _ = drag(&m, by: -260)
        _ = m.reduce(.scrolled(distance: 40))
        let fx = m.reduce(.phase(.idle))
        #expect(m.mode == .following)
        #expect(fx == [.log("detached → following (scroll ended near the end)"), .holdTopRow(false), .toEnd(animated: true)])
        #expect(!m.unseenBelow)
    }

    @Test func detachedScrollEndingFarAwayStaysDetached() {
        var m = machine(.detached, distance: 3000)
        _ = drag(&m, by: -200)
        _ = m.reduce(.scrolled(distance: 2800))
        #expect(m.reduce(.phase(.idle)) == [])
        #expect(m.mode == .detached)
    }

    @Test func detachedJumpFromAnOlderStretchLoadsTheLatestFirst() {
        var m = machine(.detached, distance: 3000)
        let fx = m.reduce(.jump(viewingPast: true, screens: 3))
        #expect(m.mode == .returning)
        #expect(fx == [.log("detached → returning (jump)"), .holdTopRow(false), .loadLatestThenEnd, .checkLanding])
    }

    @Test func detachedJumpFromFarAwayGoesStraightThere() {
        var m = machine(.detached, distance: 40_000)
        let fx = m.reduce(.jump(viewingPast: false, screens: 46))
        #expect(m.mode == .returning)
        #expect(fx.contains(.toEnd(animated: false)))
    }

    @Test func detachedJumpFromCloseAnimates() {
        var m = machine(.detached, distance: 900)
        let fx = m.reduce(.jump(viewingPast: false, screens: 1.1))
        #expect(fx.contains(.toEnd(animated: true)))
        #expect(!m.unseenBelow)
    }

    // MARK: returning

    @Test func returningLandsAndFollows() {
        var m = machine(.returning, distance: 2000)
        _ = m.reduce(.phase(.animating))
        #expect(m.reduce(.phase(.idle)) == [.checkLanding])
        let fx = m.reduce(.landed(distance: 0))
        #expect(m.mode == .following)
        #expect(fx == [.log("returning → following (landed)")])
    }

    @Test func returningLandedShortGoesTheRestAtOnce() {
        var m = machine(.returning, distance: 13_000)
        let fx = m.reduce(.landed(distance: 12_900))
        #expect(m.mode == .following)
        #expect(fx.last == .toEnd(animated: false))
    }

    @Test func returningTouchWithoutDragFinishesTheWayDown() {
        var m = machine(.returning, distance: 600)
        var fx = m.reduce(.phase(.tracking))
        fx += m.reduce(.finger(0))
        // A landing check while the finger is down waits for the finger.
        fx += m.reduce(.landed(distance: 600))
        #expect(m.mode == .returning)
        fx += m.reduce(.phase(.idle))
        #expect(m.mode == .following)
        #expect(fx == [.log("returning → following (touched on the way)"), .toEnd(animated: true)])
    }

    @Test func returningDragTowardOlderLetsGo() {
        var m = machine(.returning, distance: 600)
        let fx = drag(&m, by: 30)
        #expect(m.mode == .detached)
        #expect(fx.first == .log("returning → detached (drag)"))
        _ = m.reduce(.scrolled(distance: 630))
        #expect(m.reduce(.phase(.idle)) == [])
        #expect(m.mode == .detached)
    }

    // MARK: any

    @Test(arguments: [M.Mode.following, .detached, .returning])
    func revealCentersAndDetaches(_ mode: M.Mode) {
        var m = machine(mode, distance: 500)
        let fx = m.reduce(.reveal(id: "m42"))
        #expect(m.mode == .detached)
        #expect(fx.last == .center(id: "m42"))
        if mode != .detached {
            #expect(fx.contains(.holdTopRow(true)))
        }
    }

    @Test func foregroundCatchUpFollowingLandsOnTheEnd() {
        var m = machine(.following)
        _ = m.reduce(.scrolled(distance: 40))
        #expect(m.reduce(.foreground) == [.toEnd(animated: false)])
        #expect(m.mode == .following)
    }

    @Test func foregroundCatchUpDetachedStaysPut() {
        var m = machine(.detached, distance: 5000)
        #expect(m.reduce(.foreground) == [])
        #expect(m.mode == .detached)
    }

    @Test(arguments: [M.Mode.following, .detached, .returning])
    func backgroundOnlyLogs(_ mode: M.Mode) {
        var m = machine(mode, distance: 200)
        #expect(m.reduce(.background) == [.log("background: \(mode.rawValue)")])
        #expect(m.mode == mode)
    }

    @Test func theButtonShowsOnlyDetachedAndAwayFromTheEnd() {
        var m = machine(.detached, distance: 40)
        #expect(!m.showsJump)
        _ = m.reduce(.scrolled(distance: 140))
        #expect(m.showsJump)
        #expect(!machine(.following, distance: 4000).showsJump)
    }
}
