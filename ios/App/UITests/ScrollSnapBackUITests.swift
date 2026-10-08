import XCTest

/// The snap-backs on the iPhone 16 (2026-10-07), with real touches:
/// 1. 「回到最新」, then a finger that comes down right after and rests: the
///    view must stay on the end (it used to jump back into the middle).
/// 2. Reading back in history and scrolling down slowly: the view must never
///    jump back to an earlier message.
/// The app's debug.log (read from the simulator's data directory) says where
/// each jump landed and, under `-pinTrace YES`, why the view let go of the end.
/// Extra launch arguments come from `STRESS_ARGS` (`TEST_RUNNER_STRESS_ARGS`),
/// e.g. `-readingAnchor NO`.
final class ScrollSnapBackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: symptom 1

    @MainActor
    func testRestingFingerAfterJumpStaysAtEnd() throws {
        try restingFingerAfterJump(afterReconnect: false)
    }

    @MainActor
    func testRestingFingerAfterJumpRightAfterReconnect() throws {
        try restingFingerAfterJump(afterReconnect: true)
    }

    @MainActor
    private func restingFingerAfterJump(afterReconnect: Bool, args: [String] = ["-demoState", "stress"]) throws {
        let app = launch(args)
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4) // a reply is streaming from 3 s in

        // About 20 screens up into the history.
        for _ in 0..<3 { list.swipeDown(velocity: .fast) }
        let jump = app.buttons["jumpToLatest"]
        guard jump.waitForExistence(timeout: 5) else {
            XCTFail("no 回到最新 after scrolling up")
            return
        }
        let log = AppLog()
        if afterReconnect {
            // `-demoState stress` drops the link every 5 s; the catch-up then
            // inserts messages next to the streaming reply. Tap right after one.
            let before = log.count("connection: online")
            XCTAssertTrue(log.wait(timeout: 8) { $0.count("connection: online") > before }, "no reconnect seen")
        }
        // Tap by position (no second lookup), then a finger comes down within
        // 0.3–1 s and rests 0.5 s, then a 20 pt drag each way. It lands in the
        // list's left margin: held on a reply, it would select text instead.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let f = jump.frame
        let mid = origin.withOffset(CGVector(dx: 8, dy: list.frame.midY))
        origin.withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        let tapped = Date()
        let wait = 0.6 - Date().timeIntervalSince(tapped)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        mid.press(forDuration: 0.5, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: 20)),
                  withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertFalse(jump.exists, "回到最新 came back after the drag up")
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: -20)),
                  withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(3)
        XCTAssertFalse(jump.exists, "回到最新 came back: the view let go of the end")

        // What the app saw.
        let lines = log.lines(containing: ["[jump]", "[pin]", "connection: online"])
        let report = lines.suffix(80).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")
        guard let landing = log.lastJump("+1.2 s") else {
            XCTFail("no [jump] +1.2 s line")
            return
        }
        XCTAssertLessThanOrEqual(landing.distance, 13, "1.2 s after the tap the view was \(landing.distance) pt from the end")
        XCTAssertTrue(landing.pinned, "1.2 s after the tap the view no longer followed the end")
        if let later = log.lastJump("+3 s") {
            XCTAssertLessThanOrEqual(later.distance, 56, "3 s after the tap the view was \(later.distance) pt from the end")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: symptom 2

    @MainActor
    func testSlowScrollDownWhileStreamingNeverGoesBack() throws {
        try slowScrollDown(["-demoState", "stress"])
    }

    @MainActor
    func testSlowScrollDownIdleNeverGoesBack() throws {
        // The same long conversation, with nothing streaming.
        try slowScrollDown(["-demoState", "long", "-demoStreamDelay", "600"])
    }

    @MainActor
    private func slowScrollDown(_ args: [String]) throws {
        let app = launch(args + ["-topRowTrace", "YES"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4)
        let log = AppLog()

        // About 40 messages up: the history is m1…m180 (90 questions and
        // answers), the catch-ups and replies come after it.
        let target = 180 - 40
        var swipes = 0
        while (log.topRow() ?? Int.max) > target + 12, swipes < 14 {
            list.swipeDown(velocity: .fast)
            sleep(1)
            swipes += 1
        }
        while (log.topRow() ?? Int.max) > target, swipes < 40 {
            list.swipeDown(velocity: .slow)
            usleep(500_000)
            swipes += 1
        }
        sleep(1)
        XCTAssertTrue(app.buttons["jumpToLatest"].exists, "not detached from the end")

        // 15 slow steps down: the message at the top only ever moves on to
        // later ones, never back to an earlier one.
        let first = log.topRows().count
        var steps: [String] = ["start: top m\(log.topRow() ?? -1) after \(swipes) swipes, \(log.distance() ?? -1) pt from the end"]
        for step in 1...15 {
            let seen = log.topRows().count
            list.swipeUp(velocity: .slow)
            usleep(700_000)
            let rows = Array(log.topRows()[seen...])
            steps.append("step \(step): " + (rows.isEmpty ? "no change" : rows.map { "m\($0)" }.joined(separator: " ")))
        }
        let walked = Array(log.topRows()[first...])
        let back = zip(walked, walked.dropFirst()).filter { $1 < $0 }
        steps.append("went back \(back.count) times" + (back.isEmpty ? "" : ": " + back.map { "m\($0) → m\($1)" }.joined(separator: ", ")))
        let report = steps.joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- steps\n\(report)")
        XCTAssertFalse(walked.isEmpty, "the top message never changed")
        XCTAssertTrue(back.isEmpty, "scrolling down went back to an earlier message: \(back)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: following while a reply streams

    /// The other side of not letting go on a resting finger: a real fling up
    /// from the end while a reply streams must still let go of the end, and
    /// stay up in the history.
    @MainActor
    func testFlingUpWhileStreamingLetsGo() throws {
        let app = launch(["-demoState", "stress", "-scrollTrace", "YES"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4)
        let jump = app.buttons["jumpToLatest"]
        let log = AppLog()
        for round in 1...3 {
            list.swipeDown(velocity: .fast)
            sleep(3)
            let away = log.distance() ?? -1
            print("---- round \(round): \(away) pt from the end, button \(jump.exists)")
            XCTAssertTrue(jump.exists, "round \(round): still following the end after a fling up (\(away) pt from it)")
            XCTAssertGreaterThan(away, 1000, "round \(round): the fling up didn't stay up")
            if jump.exists { jump.tap() }
            sleep(2)
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: helpers

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES", "-pinTrace", "YES"] + args
        if let extra = ProcessInfo.processInfo.environment["STRESS_ARGS"] {
            app.launchArguments += extra.split(separator: " ").map(String.init)
        }
        app.launch()
        return app
    }
}

/// The app's debug.log in the simulator (each launch starts a new one).
struct AppLog {
    let url: URL?

    init() {
        let fm = FileManager.default
        let root = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("Containers/Data/Application")
        }
        let logs = (root.flatMap { try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? [])
            .map { $0.appendingPathComponent("Documents/debug.log") }
            .filter { fm.fileExists(atPath: $0.path) }
        url = logs.max { a, b in
            let da = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
            return da < db
        }
    }

    var text: String { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }

    func count(_ s: String) -> Int { text.components(separatedBy: s).count - 1 }

    func lines(containing any: [String]) -> [String] {
        text.split(separator: "\n").map(String.init).filter { l in any.contains { l.contains($0) } }
    }

    func wait(timeout: TimeInterval, until ok: (AppLog) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok(self) { return true }
            usleep(50_000)
        }
        return false
    }

    /// `[top] mN` lines (`-topRowTrace YES`): the message under the top of the view.
    func topRows() -> [Int] {
        lines(containing: ["[top] m"]).compactMap { l in
            l.range(of: #"\[top\] m\d+$"#, options: .regularExpression).flatMap { Int(l[$0].dropFirst(7)) }
        }
    }

    func topRow() -> Int? { topRows().last }

    /// The distance from the end in the last `[pin]` line (`-pinTrace YES`).
    func distance() -> Int? {
        guard let l = lines(containing: ["[pin]"]).last,
              let r = l.range(of: #"-?\d+ pt from the end"#, options: .regularExpression)
        else { return nil }
        return Int(l[r].split(separator: " ")[0])
    }

    /// The last `[jump] <when>: N pt from the end, pinned B` line.
    func lastJump(_ when: String) -> (distance: Int, pinned: Bool)? {
        guard let l = lines(containing: ["[jump] \(when):"]).last,
              let r = l.range(of: #"-?\d+ pt from the end"#, options: .regularExpression),
              let d = Int(l[r].split(separator: " ")[0])
        else { return nil }
        return (d, l.hasSuffix("pinned true"))
    }
}
