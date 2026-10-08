import XCTest

/// Step 0 of the chat scroll redesign: runs the scroll lab
/// (`-demoScreen scrollLab`) and prints its `[lab]` findings from the app's
/// debug.log. No pass/fail beyond the lab finishing: the lines are the result.
final class ScrollLabUITests: XCTestCase {
    @MainActor
    func testLabAnchor() throws {
        try lab("anchor", until: "[lab] anchor done", timeout: 90)
    }

    @MainActor
    func testLabWidth() throws {
        try lab("width", until: "[lab] width done", timeout: 90)
    }

    @MainActor
    func testLabSentinel() throws {
        try lab("sentinel", until: "[lab] sentinel done", timeout: 40)
    }

    /// A fling toward older rows from the end; 150 ms in, the lab scrolls to
    /// the end (animated, instantly, or not at all). Then a drag that holds,
    /// with the command 300 ms into the drag.
    @MainActor
    func testLabFling() throws {
        var report: [String] = []
        for mode in ["animated", "instant", "none", "duringDrag"] {
            let app = XCUIApplication()
            app.launchArguments += ["-demo", "YES", "-demoScreen", "scrollLab", "-labRun", "fling", "-labFlingMode", mode]
            app.launch()
            sleep(3)
            let window = app.windows.firstMatch
            if mode == "duringDrag" {
                let mid = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                mid.press(forDuration: 0.1, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: 250)),
                          withVelocity: .slow, thenHoldForDuration: 1.5)
            } else {
                window.swipeDown(velocity: .fast)
            }
            sleep(4)
            let log = AppLog()
            report += ["== \(mode)"] + log.lines(containing: ["[lab] fling |", "[lab] fling phase", "[lab] fling mode"])
            app.terminate()
        }
        let text = report.joined(separator: "\n")
        add(XCTAttachment(string: text))
        print("---- lab\n\(text)")
    }

    /// The end grows every 120 ms for 8 s; meanwhile a finger rests 2 s,
    /// then drags 30 pt toward older rows and holds 1.5 s (exact times: the
    /// growing list never lets XCUI's own gestures run on time).
    @MainActor
    func testLabTouch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES", "-demoScreen", "scrollLab", "-labRun", "touch"]
        app.launch()
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: 20) { _ in AppLog().count("[lab] touch growing") > 0 })
        let f = app.windows.firstMatch.frame
        let mid = CGPoint(x: f.midX, y: f.midY)
        let started = Date()
        try TouchScript.play([
            .hold(at: mid, from: 0.5, for: 2.0),
            .drag(at: mid, from: 3.2, dy: 30, over: 0.3, hold: 1.5),
        ])
        print("---- the touch script took \(Date().timeIntervalSince(started)) s")
        XCTAssertTrue(log.wait(timeout: 20) { _ in AppLog().count("[lab] touch done") > 0 })
        let text = AppLog().lines(containing: ["[lab]"]).joined(separator: "\n")
        add(XCTAttachment(string: text))
        print("---- lab\n\(text)")
    }

    @MainActor
    private func lab(_ run: String, until done: String, timeout: TimeInterval) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES", "-demoScreen", "scrollLab", "-labRun", run]
        app.launch()
        let log = AppLog()
        XCTAssertTrue(log.wait(timeout: timeout) { _ in AppLog().count(done) > 0 }, "the lab didn’t finish")
        let text = AppLog().lines(containing: ["[lab]"]).joined(separator: "\n")
        add(XCTAttachment(string: text))
        print("---- lab\n\(text)")
    }
}
