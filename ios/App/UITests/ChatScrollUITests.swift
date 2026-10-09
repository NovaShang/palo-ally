import XCTest

/// The chat scroll redesign's tests (design §6), against the demo host on an
/// iPhone simulator, with real touches. Each reads the app's debug.log:
/// `[scroll]` transitions, `[jump]` landings, `[stall]` lines, and under
/// `-pinTrace` / `-topRowTrace` / `-scrollTrace` the phases, the message at
/// the top and the raw geometry. Extra launch arguments come from
/// `STRESS_ARGS` (`TEST_RUNNER_STRESS_ARGS` for xcodebuild).
///
/// - T2: 「回到最新」, then a finger resting at +0.3 s and +1.0 s, then a
///   20 pt drag each way: the view stays on the end. Idle, right after a
///   reconnect, and with a reply streaming.
/// - T3: reading back ~40 messages, 15 slow swipes down: never back to an
///   earlier message. Idle and streaming.
/// - T4: holding to talk while a whole reply lands at once: no stall.
/// - T5: leaving the app mid-reply and coming back: no long stall, the view
///   where it was.
/// - Far jump: from ~40 000 pt up, 「回到最新」 lands on the end.
/// - A fling up while a reply streams lets go of the end.
final class ChatScrollUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        // A failed rotation test must not leave the next one in landscape.
        await MainActor.run {
            if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        }
    }

    // MARK: T2

    @MainActor
    func testT2JumpThenRestingFingerIdle() throws {
        try jumpThenRestingFinger(["-demoState", "long", "-demoStreamDelay", "600"], afterReconnect: false)
    }

    @MainActor
    func testT2JumpThenRestingFingerRightAfterReconnect() throws {
        try jumpThenRestingFinger(["-demoState", "stress"], afterReconnect: true)
    }

    @MainActor
    func testT2JumpThenRestingFingerWhileStreaming() throws {
        try jumpThenRestingFinger(["-demoState", "stress"], afterReconnect: false)
    }

    @MainActor
    private func jumpThenRestingFinger(_ args: [String], afterReconnect: Bool) throws {
        let app = launch(args)
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4) // under -demoState stress a reply streams from 3 s in

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
        // One script, so the times hold while the app is busy: the tap; a
        // finger resting 0.5 s from +0.3 s and from +1.0 s; a 20 pt drag up,
        // then down. In the list's left margin: held on a reply, a finger
        // would select text instead.
        let f = jump.frame
        let lf = list.frame
        let margin = CGPoint(x: lf.minX + 8, y: lf.midY)
        let started = Date()
        try TouchScript.play([
            .tap(at: CGPoint(x: f.midX, y: f.midY), time: 0),
            .hold(at: margin, from: 0.3, for: 0.5),
            .hold(at: margin, from: 1.0, for: 0.5),
            .drag(at: margin, from: 1.8, dy: -20),
            .drag(at: margin, from: 2.6, dy: 20),
        ])
        let took = Date().timeIntervalSince(started)
        sleep(4)

        let lines = log.lines(containing: ["[jump]", "[pin]", "[scroll]", "connection: online"])
        let report = (["touch script took \(String(format: "%.2f", took)) s"] + lines.suffix(80)).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")

        XCTAssertFalse(jump.exists, "回到最新 came back: the view let go of the end")
        guard let tap = log.entries(containing: ["[jump] tap"]).last?.time else {
            XCTFail("the jump never ran")
            return
        }
        // While the finger rests (tap … +1.5 s), nothing lets go of the end.
        let letGo = log.entries(containing: ["[scroll] following → detached"])
            .filter { $0.time >= tap && $0.time <= tap.addingTimeInterval(1.6) }
        XCTAssertTrue(letGo.isEmpty, "let go of the end under a resting finger: \(letGo.map(\.line))")
        if let landing = log.lastJump("+1.2 s") {
            XCTAssertTrue(landing.onTheEnd, "1.2 s after the tap the view was \(landing.distance) pt from the end")
            XCTAssertTrue(landing.pinned, "1.2 s after the tap the view no longer followed the end")
        } else {
            XCTFail("no [jump] +1.2 s line")
        }
        // After the drags: back on the end, following it.
        if let settled = log.lastJump("+5 s") {
            XCTAssertTrue(settled.onTheEnd, "5 s after the tap the view was \(settled.distance) pt from the end")
            XCTAssertTrue(settled.pinned, "5 s after the tap the view no longer followed the end")
        } else {
            XCTFail("no [jump] +5 s line")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: T3

    @MainActor
    func testT3SlowScrollDownIdle() throws {
        try slowScrollDown(["-demoState", "long", "-demoStreamDelay", "600"])
    }

    @MainActor
    func testT3SlowScrollDownWhileStreaming() throws {
        try slowScrollDown(["-demoState", "stress"])
    }

    @MainActor
    private func slowScrollDown(_ args: [String]) throws {
        let app = launch(args + ["-topRowTrace", "YES", "-scrollTrace", "YES"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4)
        let log = AppLog()

        // About 40 messages up: the history is m1…m180 (90 questions and
        // answers); the catch-ups and replies come after it.
        let target = 180 - 40
        var swipes = 0
        // (At least a few swipes: the message logged at the top while the
        // list first lays out can be anything.)
        while swipes < 4 || (log.topRow() ?? Int.max) > target + 12, swipes < 14 {
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
        let start = log.topRow() ?? Int.max
        XCTAssertLessThanOrEqual(start, target + 6, "couldn't get ~40 messages up: the top is m\(start) after \(swipes) swipes")

        // 15 slow steps down: the message at the top only ever moves on to
        // later ones; the offset never goes back by more than 2 pt while the
        // content height holds.
        let first = log.topRows().count
        let firstGeo = log.geometry().count
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
        let geo = Array(log.geometry()[firstGeo...])
        // (Not at the end, where a stretch past it springs back.)
        let jumps = zip(geo, geo.dropFirst()).filter { $0.h == $1.h && $1.y < $0.y - 2 && $0.distance > 1 && $1.distance > 1 }
        steps.append("went back \(back.count) times" + (back.isEmpty ? "" : ": " + back.map { "m\($0) → m\($1)" }.joined(separator: ", ")))
        steps.append("offset went back > 2 pt (same height) \(jumps.count) times" +
                     (jumps.isEmpty ? "" : ": " + jumps.prefix(8).map { "\($0.y) → \($1.y)" }.joined(separator: ", ")))
        let report = steps.joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- steps\n\(report)")
        XCTAssertFalse(walked.isEmpty, "the top message never changed")
        XCTAssertTrue(back.isEmpty, "scrolling down went back to an earlier message: \(back)")
        XCTAssertTrue(jumps.isEmpty, "the offset jumped back while scrolling down: \(jumps.prefix(8))")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: T4

    /// 何子安's 17:49 freeze: holding to talk while 110 deltas, the final
    /// message and the host going idle all land at once.
    @MainActor
    func testT4HoldToTalkThroughABurst() throws {
        let app = launch(["-demoState", "burst", "-demoBurstAt", "9",
                          "-voiceDrill", "6", "-voiceDrillDelay", "6", "-voiceDrillAudio", "YES",
                          "-speech_engine", "apple", "-stallThresholdMs", "100"])
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 30) { $0.count("[demo] burst") > 0 }, "the burst never came")
        sleep(5)
        let lines = log.lines(containing: ["[stall]", "[drill]", "[demo]", "[reveal]", "[voice]"])
        add(XCTAttachment(string: lines.joined(separator: "\n")))
        print("---- app log\n\(lines.joined(separator: "\n"))")
        guard let held = log.entries(containing: ["[drill] hold to talk"]).last?.time else {
            XCTFail("the drill never held")
            return
        }
        XCTAssertTrue(log.count("[drill] press refused") == 0, "the drill's press was refused")
        let stalls = log.stalls().filter { $0.time >= held }
        let worst = stalls.map(\.ms).max() ?? 0
        print("---- stalls after the hold began: \(stalls.map(\.ms))")
        XCTAssertLessThan(worst, 250, "the main thread stalled \(worst) ms while holding to talk through the burst")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: T5

    @MainActor
    func testT5BackgroundMidReplyFollowing() throws {
        try backgroundMidReply(detached: false)
    }

    @MainActor
    func testT5BackgroundMidReplyDetached() throws {
        try backgroundMidReply(detached: true)
    }

    @MainActor
    private func backgroundMidReply(detached: Bool) throws {
        let app = launch(["-demoState", "stress", "-stallThresholdMs", "100", "-topRowTrace", "YES"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(6) // a reply streams from 3 s in
        let log = AppLog()
        if detached {
            list.swipeDown(velocity: .slow)
            sleep(2)
        }
        let topBefore = log.topRow()
        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        sleep(4)

        let lines = log.lines(containing: ["[scroll]", "[stall]", "[reveal]", "connection:"])
        add(XCTAttachment(string: lines.suffix(60).joined(separator: "\n")))
        print("---- app log\n\(lines.suffix(60).joined(separator: "\n"))")
        guard let away = log.entries(containing: ["[scroll] background"]).last,
              let back = log.entries(containing: ["[scroll] foreground"]).last
        else {
            XCTFail("no [scroll] background / foreground lines")
            return
        }
        // Leaving: the stalls around going to the background.
        let leaving = log.stalls().filter { $0.time >= away.time.addingTimeInterval(-1) && $0.time <= away.time.addingTimeInterval(3) }
        let worst = leaving.map(\.ms).max() ?? 0
        XCTAssertLessThan(worst, 300, "going to the background stalled \(worst) ms")
        if detached {
            XCTAssertTrue(back.line.contains("detached"), "came back following the end: \(back.line)")
            XCTAssertEqual(log.topRow(), topBefore, "came back to a different message at the top")
        } else {
            XCTAssertTrue(back.line.contains("following"), "came back no longer following: \(back.line)")
            let d = AppLog.number(before: "pt from the end", in: back.line) ?? -1
            XCTAssertLessThanOrEqual(d, 13, "came back \(d) pt from the end")
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    // MARK: far jump

    @MainActor
    func testFarJumpLandsOnTheEndIdle() throws {
        try farJump(["-demoState", "long", "-demoStreamDelay", "600"])
    }

    @MainActor
    func testFarJumpLandsOnTheEndWhileStreaming() throws {
        try farJump(["-demoState", "stress"])
    }

    /// From ~40 000 pt up 「回到最新」 used to stop where the fully laid-out
    /// end begins, ~12 900 pt short. Far up by `-demoDetach` (reading from the
    /// middle of the conversation, ~90 messages back).
    @MainActor
    private func farJump(_ args: [String]) throws {
        let app = launch(args + ["-demoDetach", "YES"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 20) { $0.count("[anchor] reading from") > 0 }, "never went up to read")
        sleep(3)
        let jump = app.buttons["jumpToLatest"]
        guard jump.waitForExistence(timeout: 5) else {
            XCTFail("no 回到最新 up in the history")
            return
        }
        let f = jump.frame
        try TouchScript.play([.tap(at: CGPoint(x: f.midX, y: f.midY), time: 0)])
        sleep(6)
        let from = log.lines(containing: ["[jump] tap:"]).last.flatMap { AppLog.number(before: "pt from the end", in: $0) } ?? -1
        let lines = log.lines(containing: ["[jump]", "[scroll]"])
        let report = (["from \(from) pt up"] + lines.suffix(20)).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")
        // Reading from the middle lays a window of its own out around it
        // (design §3.4), so how far up that is in points depends on what is
        // laid out; the jump has to lay the end out again and land on it.
        XCTAssertGreaterThanOrEqual(from, 2_000, "didn't get far enough up")
        for when in ["+1.2 s", "+3 s", "+5 s"] {
            guard let j = log.lastJump(when) else {
                XCTFail("no [jump] \(when) line")
                continue
            }
            XCTAssertTrue(j.onTheEnd, "\(when) after the tap the view was \(j.distance) pt from the end")
            XCTAssertTrue(j.pinned, "\(when) after the tap the view didn't follow the end")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: the row being read stays put

    @MainActor
    func testHeldRowStaysThroughRotationIdle() throws {
        try heldRowThroughRotation(["-demoState", "long", "-demoStreamDelay", "600"])
    }

    @MainActor
    func testHeldRowStaysThroughRotationWhileStreaming() throws {
        try heldRowThroughRotation(["-demoState", "stress"])
    }

    /// Reading from the middle (`-demoDetach`): the window grows above the
    /// row being read a few rows at a time, then the phone turns to
    /// landscape and back (every row rewraps). The row stays where it was
    /// on screen, and once the layout stops changing the corrections stop:
    /// holding the row doesn't feed itself (next to the old lazy history it
    /// did, 12 s of main thread), and its breaker never trips.
    @MainActor
    private func heldRowThroughRotation(_ args: [String]) throws {
        let app = launch(args + ["-demoDetach", "YES", "-topRowTrace", "YES"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 20), "the conversation never appeared")
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 20) { $0.count("[anchor] reading from") > 0 }, "never went up to read")
        sleep(5) // the window grows above the row, a step at a time
        let target = log.lines(containing: ["[anchor] reading from m"]).last
            .flatMap { l in l.range(of: #"m\d+$"#, options: .regularExpression).map { Int(l[$0].dropFirst()) } } ?? nil
        let topBefore = log.topRow()
        func held() -> (id: String, y: Int)? {
            guard let l = log.lines(containing: ["[hold] "]).last,
                  let r = l.range(of: #"\[hold\] \S+ at -?\d+ pt"#, options: .regularExpression) else { return nil }
            let parts = l[r].split(separator: " ")
            return (String(parts[1]), Int(parts[3]) ?? .min)
        }
        guard let before = held() else {
            XCTFail("no row was held")
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let landscape = held()
        XCUIDevice.shared.orientation = .portrait
        sleep(4)
        let after = held()
        let topAfter = log.topRow()
        let corrections = log.entries(containing: ["[pin] holding "])
        let settledSince = Date().addingTimeInterval(-2)
        let late = corrections.filter { $0.time > settledSince }
        let report = ["held before: \(before)", "in landscape: \(String(describing: landscape))", "after: \(String(describing: after))",
                      "\(corrections.count) corrections, \(late.count) in the last 2 s"]
            + log.lines(containing: ["[hold]", "[scroll]", "stopped holding"]).suffix(30)
        add(XCTAttachment(string: report.joined(separator: "\n")))
        print("---- held row\n\(report.joined(separator: "\n"))")
        XCTAssertEqual(after?.id, before.id, "a different row is held after turning the phone")
        // The row held is one near the message read (not a row long gone),
        // and the message at the top of the view is the same as before.
        if let target, let n = Int(before.id.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(n - target), 4, "held \(before.id), reading from m\(target)")
        }
        XCTAssertEqual(topAfter, topBefore, "a different message is at the top after turning the phone")
        if let after {
            XCTAssertLessThanOrEqual(abs(after.y - before.y), 2, "the row being read moved \(after.y - before.y) pt")
        }
        XCTAssertEqual(log.count("stopped holding the top row"), 0, "holding the row tripped its breaker")
        XCTAssertTrue(late.isEmpty, "still correcting with nothing changing: \(late.count) in the last 2 s")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: following while a reply streams

    /// The other side of not letting go on a resting finger: a real fling up
    /// from the end while a reply streams must still let go of the end, and
    /// stay up in the history.
    @MainActor
    func testFlingUpWhileStreamingLetsGo() throws {
        let app = launch(["-demoState", "stress"])
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

    // MARK: short flick

    /// Her phone (the step 3 build): a quick flick up from the end let go of
    /// it ("drag"), coasted 200–750 pt, and was then taken back to the end as
    /// a short drag ("scroll ended near the end"). A flick moves the finger
    /// less than the 56 pt a short drag allows; only its speed tells them apart.
    @MainActor
    func testShortFlickFromTheEndStaysUpIdle() throws {
        try shortFlick(["-demoState", "long", "-demoStreamDelay", "600"])
    }

    @MainActor
    func testShortFlickFromTheEndStaysUpWhileStreaming() throws {
        try shortFlick(["-demoState", "stress"])
    }

    @MainActor
    private func shortFlick(_ args: [String]) throws {
        let app = launch(args)
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(5)
        let log = AppLog()
        let lf = list.frame
        // In the list's left margin: held on a reply, a finger selects text.
        let margin = CGPoint(x: lf.minX + 8, y: lf.midY)
        let jump = app.buttons["jumpToLatest"]
        for round in 1...3 {
            let returnsBefore = log.count("(scroll ended near the end)")
            // 50 pt in a tenth of a second, up while still moving. The list
            // follows the finger only past the pan's slop, so it counts less
            // than the 56 pt a short drag may be.
            try TouchScript.play([.fling(at: margin, dy: 50, from: 0)])
            sleep(3)
            let away = log.distance() ?? -1
            let returned = log.count("(scroll ended near the end)") - returnsBefore
            print("---- round \(round): \(away) pt from the end, taken back \(returned) times")
            XCTAssertEqual(returned, 0, "round \(round): a short flick up was taken back to the end (\(away) pt from it)")
            // (Past the 56 pt within which the end is still "near".)
            XCTAssertGreaterThan(away, 60, "round \(round): a short flick up didn't stay up")
            if jump.exists {
                let f = jump.frame
                try TouchScript.play([.tap(at: CGPoint(x: f.midX, y: f.midY), time: 0)])
            }
            sleep(3)
        }
        let lines = log.lines(containing: ["[scroll]", "[pin]"])
        add(XCTAttachment(string: lines.suffix(80).joined(separator: "\n")))
        print("---- app log\n" + lines.suffix(60).joined(separator: "\n"))
    }

    // MARK: her phone: the breaker after a reconnect, a far jump and reading back

    /// Her phone (step 4 build): a reconnect, 「回到最新」 from 12 000 pt, a
    /// drag up to about 1000 pt from the end, and some 13 s later the row
    /// being read was let go of: "corrections kept coming (a loop)". The same
    /// moves under the stress demo (reconnects every 5 s, replies streaming),
    /// then 15 s of reading: the row stays held, the breaker never trips.
    @MainActor
    func testReadingBackAfterReconnectAndJumpKeepsItsRow() throws {
        let app = launch(["-demoState", "stress"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        sleep(4)
        for _ in 0..<3 { list.swipeDown(velocity: .fast) }
        let jump = app.buttons["jumpToLatest"]
        guard jump.waitForExistence(timeout: 5) else { return XCTFail("no 回到最新 after scrolling up") }
        let log = AppLog()
        let before = log.count("connection: online")
        XCTAssertTrue(log.wait(timeout: 8) { $0.count("connection: online") > before }, "no reconnect seen")
        let f = jump.frame
        let lf = list.frame
        let margin = CGPoint(x: lf.minX + 8, y: lf.minY + lf.height * 0.3)
        // The tap; 1.8 s on, a drag up into the history, and another: about
        // 1000 pt from the end. Then nothing: reading.
        try TouchScript.play([
            .tap(at: CGPoint(x: f.midX, y: f.midY), time: 0),
            .drag(at: margin, from: 1.8, dy: 300, over: 0.6, hold: 0.2),
            .drag(at: margin, from: 3.2, dy: 400, over: 0.8, hold: 0.2),
        ])
        let readFrom = Date()
        sleep(15)
        let report = log.lines(containing: ["[jump]", "[scroll]", "[hold]", "connection: online"]).suffix(60).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")
        XCTAssertEqual(log.count("stopped holding the top row"), 0, "the breaker tripped: \(log.lines(containing: ["stopped holding"]))")
        // While reading (from a second after the last drag), the held row stays put.
        let holds = log.entries(containing: ["[hold]"]).filter { $0.time > readFrom.addingTimeInterval(1) }
        let ys = holds.compactMap { AppLog.number(before: "pt below the top", in: $0.line) }
        if let first = ys.first {
            XCTAssertLessThanOrEqual(ys.map { abs($0 - first) }.max() ?? 0, 2, "the row being read moved: \(ys)")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: sending: the message to the top (design §3.5, Q1)

    /// A short reply: the sent message rises to the top of the view, and then
    /// nothing scrolls at all while the reply is written below it.
    @MainActor
    func testSendShortReplyDoesNotScroll() throws {
        let app = launch(["-demoState", "long", "-demoStreamDelay", "600", "-demoSends", "5:好的谢谢",
                          "-turnTrace", "YES", "-frameTrace", "YES"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 20), "the conversation never appeared")
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 25) { $0.count("[frames] a send") > 0 }, "the reply never finished")
        let turns = log.entries(containing: ["[turn]"])
        let ys = turns.compactMap { AppLog.number(before: "pt below the top", in: $0.line) }
        let report = log.lines(containing: ["[turn]", "[frames]", "[scroll]", "[reveal] reply"]).suffix(60).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")
        guard let risen = ys.firstIndex(where: { $0 <= 14 }) else { return XCTFail("the sent message never reached the top: \(ys)") }
        XCTAssertGreaterThan(ys.first ?? 0, 100, "the sent message didn't rise from below: \(ys)")
        // From the top on, it stays there through the whole reply.
        let after = ys[risen...]
        XCTAssertLessThanOrEqual(after.map { abs($0 - 12) }.max() ?? 0, 2, "the view moved while a short reply was written: \(Array(after))")
        XCTAssertEqual(log.count("stopped short"), 0, "the send's scroll didn't land: \(log.lines(containing: ["stopped short"]))")
        XCTAssertEqual(log.count("thrown off the end"), 0)
    }

    /// A reply longer than the screen: the sent message rises to the top; once
    /// the reply fills the room below it, the view follows the end, gliding
    /// (no step of a whole line from one frame to the next), with the end in
    /// view, and frames on time.
    @MainActor
    func testSendLongReplyFollowsSmoothlyAfterItOverflows() throws {
        let app = launch(["-demoState", "long", "-demoStreamDelay", "600", "-demoSends", "5:写详细一点",
                          "-turnTrace", "YES", "-frameTrace", "YES"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 20), "the conversation never appeared")
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 40) { $0.count("[frames] a send") > 0 }, "the reply never finished")
        let report = log.lines(containing: ["[turn]", "[frames]", "[scroll]", "[reveal] reply"]).suffix(80).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")
        let turns = log.lines(containing: ["[turn]"])
        let ys = turns.compactMap { AppLog.number(before: "pt below the top", in: $0) }
        let ends = turns.compactMap { AppLog.number(before: "pt from the end", in: $0) }
        XCTAssertNotNil(ys.firstIndex(where: { $0 <= 14 }), "the sent message never reached the top: \(ys.prefix(40))")
        XCTAssertLessThan(ys.last ?? 0, -200, "the reply didn't push the sent message up and away: \(ys.suffix(10))")
        // Following: the end never more than about two lines out of view
        // (a glide's lag at the demo's pace, 150 characters a second).
        if let risen = ys.firstIndex(where: { $0 <= 14 }) {
            XCTAssertLessThanOrEqual(ends[risen...].max() ?? 0, 75, "the end fell out of view while following")
        }
        XCTAssertEqual(ends.last, 0, "it didn't end on the end")
        // The frames while the reply was written and followed.
        guard let line = log.lines(containing: ["[frames] a send"]).last, let then = line.range(of: "then "),
              let ending = line.range(of: "; ending") else {
            return XCTFail("no [frames] line")
        }
        // While following (the reply's final message, its end, is counted apart).
        let part = String(line[then.upperBound..<ending.lowerBound])
        let step = Double(part.range(of: #"largest step [\d.]+"#, options: .regularExpression).map { part[$0].split(separator: " ").last! } ?? "99") ?? 99
        let ratio = Double(part.range(of: #"\(([\d.]+) ms/s\)"#, options: .regularExpression).map { part[$0].dropFirst().split(separator: " ").first! } ?? "99") ?? 99
        XCTAssertLessThanOrEqual(step, 15, "a step of \(step) pt between two frames: a jump, not a glide")
        XCTAssertLessThan(ratio, 5, "hitches \(ratio) ms/s while following")
    }

    /// Reading back while a long reply is written: a drag up lets go, and
    /// from then on the text being read stays where it is.
    @MainActor
    func testDetachingMidReplyHolds() throws {
        let app = launch(["-demoState", "long", "-demoStreamDelay", "600", "-demoSends", "5:写详细一点", "-turnTrace", "YES"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 20) { $0.count("[demo] sending") > 0 }, "nothing was sent")
        sleep(5) // the reply has outgrown the room and is followed
        let lf = list.frame
        let margin = CGPoint(x: lf.minX + 8, y: lf.minY + lf.height * 0.35)
        try TouchScript.play([.drag(at: margin, from: 0, dy: 160, over: 0.5, hold: 0.2)])
        let readFrom = Date()
        XCTAssertTrue(log.wait(timeout: 30) { $0.count("[reveal] reply done") > 0 }, "the reply never finished")
        sleep(1)
        let report = log.lines(containing: ["[scroll]", "[hold]", "[turn]"]).suffix(60).joined(separator: "\n")
        add(XCTAttachment(string: report))
        print("---- app log\n\(report)")
        XCTAssertEqual(log.count("following → detached (drag)"), 1, "the drag didn't let go of the end (or did twice)")
        XCTAssertEqual(log.count("detached → following"), 0, "taken back to the end while reading")
        let holds = log.entries(containing: ["[hold]"]).filter { $0.time > readFrom.addingTimeInterval(1) }
        let ys = holds.compactMap { AppLog.number(before: "pt below the top", in: $0.line) }
        if let first = ys.first {
            XCTAssertLessThanOrEqual(ys.map { abs($0 - first) }.max() ?? 0, 2, "the text being read moved as the reply grew: \(ys)")
        }
        XCTAssertEqual(log.count("stopped holding the top row"), 0)
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
