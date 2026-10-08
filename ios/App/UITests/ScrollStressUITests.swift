import XCTest

/// The iPhone freeze of 2026-10-07: flinging the conversation while a reply
/// streams in and catch-ups insert messages above it. Runs the demo host's
/// `stress` scenario and flings the list with real touches all through it.
/// The app's stall watchdog writes every main-thread stall to debug.log,
/// and each 「回到最新」 tap logs where it landed (`[jump]`); read them from the
/// simulator's app container afterwards (scripts/scroll-stress.sh).
///
/// Extra launch arguments come from the `STRESS_ARGS` environment variable
/// (`TEST_RUNNER_STRESS_ARGS` for xcodebuild), e.g. `-readingAnchor NO` to
/// run without the reading anchor (scroll position by id while detached),
/// which is on everywhere by default.
final class ScrollStressUITests: XCTestCase {
    @MainActor
    func testFlingWhileStreamingAndSyncing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES", "-demoState", "stress"]
        if let extra = ProcessInfo.processInfo.environment["STRESS_ARGS"] {
            app.launchArguments += extra.split(separator: " ").map(String.init)
        }
        app.launch()

        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4) // the first reply starts streaming 3 s in

        let jump = app.buttons["jumpToLatest"]
        let end = Date().addingTimeInterval(30) // replies stream for about a minute
        var step = 0
        while Date() < end {
            switch step % 7 {
            case 0, 1: list.swipeDown(velocity: .fast) // back into history, coasting
            case 2: list.swipeUp(velocity: .fast)
            case 3: list.swipeDown(velocity: .slow)
            case 4:
                // The button can go between finding and tapping it.
                if jump.exists { XCTExpectFailure(strict: false) { jump.tap() } } else { list.swipeUp(velocity: .fast) }
            case 5: list.swipeUp(velocity: .fast)
            default:
                // A short drag up and a hold, then let go near the end.
                let mid = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: 160)),
                          withVelocity: .fast, thenHoldForDuration: 0.2)
            }
            step += 1
        }

        // Up in history while it streams, then 「回到最新」: the button must stay
        // gone (still following the end) with the reply growing below.
        list.swipeDown(velocity: .fast)
        list.swipeDown(velocity: .fast)
        guard jump.waitForExistence(timeout: 5) else {
            XCTFail("no 回到最新 after scrolling up\n\(app.debugDescription)")
            return
        }
        jump.tap()
        sleep(3)
        XCTAssertFalse(jump.exists, "回到最新 came back: the jump didn't stay on the end")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
