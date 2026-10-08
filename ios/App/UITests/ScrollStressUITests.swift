import XCTest

/// The iPhone freeze of 2026-10-07: flinging the conversation while a reply
/// streams in and catch-ups insert messages above it. Runs the demo host's
/// `stress` scenario and flings the list with real touches all through it.
/// The app's stall watchdog writes every main-thread stall to debug.log,
/// and each 「回到最新」 tap logs where it landed (`[jump]`); read them from the
/// simulator's app container afterwards (scripts/scroll-stress.sh).
///
/// Extra launch arguments come from the `STRESS_ARGS` environment variable
/// (`TEST_RUNNER_STRESS_ARGS` for xcodebuild), e.g. `-pinTrace YES` for the
/// scroll coordinator's phases and decisions.
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

        // Where 「回到最新」 shows: once up into the history and look (before
        // the measured part: an XCUI query snapshots the whole accessibility
        // tree, every laid-out row, and that alone holds the main thread
        // 600-700 ms with a long window).
        let f = list.frame
        let mid = CGPoint(x: f.midX, y: f.midY)
        try TouchScript.play([.fling(at: mid, dy: 360, from: 0), .fling(at: mid, dy: 360, from: 1.2)])
        let jump = app.buttons["jumpToLatest"]
        guard jump.waitForExistence(timeout: 5) else {
            XCTFail("no 回到最新 after scrolling up\n\(app.debugDescription)")
            return
        }
        let jumpAt = CGPoint(x: jump.frame.midX, y: jump.frame.midY)
        try TouchScript.play([.tap(at: jumpAt, time: 0)])
        sleep(2)

        // The measured part, as one touch script (nothing waits for the app
        // to go idle, nothing queries it): flings both ways, slow drags and
        // a drag that holds, for 30 s while replies stream and catch-ups
        // land; then up into the history and 「回到最新」, which must stay on
        // the end with the reply growing below.
        let began = Date()
        var touches: [TouchScript.Touch] = []
        var t = 0.0
        for step in 0..<19 {
            switch step % 6 {
            case 0, 1: touches.append(.fling(at: mid, dy: 360, from: t)) // back into history, coasting
            case 2, 4: touches.append(.fling(at: mid, dy: -360, from: t))
            case 3: touches.append(.drag(at: mid, from: t, dy: 120, over: 0.6, hold: 0.1))
            default: touches.append(.drag(at: mid, from: t, dy: 160, over: 0.15, hold: 0.3))
            }
            t += 1.6
        }
        touches.append(.fling(at: mid, dy: 360, from: t))
        touches.append(.fling(at: mid, dy: 360, from: t + 1.2))
        touches.append(.tap(at: jumpAt, time: t + 3.5))
        try TouchScript.play(touches)
        sleep(5)
        let ended = Date()
        let log = AppLog()
        let jumps = log.lines(containing: ["[jump]"]).suffix(4)
        print("---- jumps\n\(jumps.joined(separator: "\n"))")
        for when in ["+1.2 s", "+3 s"] {
            guard let j = log.lastJump(when) else {
                XCTFail("no [jump] \(when) line")
                continue
            }
            XCTAssertLessThanOrEqual(j.distance, 13, "\(when) after the last 回到最新 the view was \(j.distance) pt from the end")
            XCTAssertTrue(j.pinned, "\(when) after the last 回到最新 the view didn't follow the end")
        }
        XCTAssertEqual(app.state, .runningForeground)

        // The gate: no stall of 250 ms or more once the reader is at it (the
        // launch itself is measured by scripts/launch-budget.sh).
        let stalls = AppLog().stalls().filter { $0.time >= began && $0.time <= ended }
        print("---- stalls while flinging: \(stalls.map(\.ms))")
        let worst = stalls.map(\.ms).max() ?? 0
        XCTAssertLessThan(worst, 250, "the main thread stalled \(worst) ms while flinging (all: \(stalls.map(\.ms)))")
        XCTAssertEqual(AppLog().count("stopped holding the top row"), 0, "holding the row being read tripped its breaker")
    }
}
