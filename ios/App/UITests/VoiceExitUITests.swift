import XCTest

/// Hold to talk, and what the words do once the finger lifts (design §3.7),
/// against the demo host on an iPhone simulator. The hold is the composer's
/// own drill (`-voiceDrill`), with scripted words (`-voiceDrillText
/// "partial|partial=>final"`), so no microphone and no recognizer: the same
/// calls the press gesture makes. Each test reads the app's debug.log:
/// `[voice]` (the exit and when it's down, with the composer and the list
/// as they're left), `[turn]` (where the sent message is), `[frames] voice`
/// (how late each frame came from release until the words were gone).
///
/// - send, short and long: the words fly into the message at the top of the
///   view (Q1); the list follows the end; no frame after the first over 33 ms.
/// - cancel: nothing sent, the composer empty, the list where it was.
/// - edit: the final words in the composer, nothing sent.
/// - nothing heard: 没听清, nothing sent.
/// - while a reply is being written: sent, and the list ends following the end.
/// Every one: no voice UI left on screen.
final class VoiceExitUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private static let short = "今天|今天天气|今天天气怎么样=>今天天气怎么样？"
    private static let longWords = "帮我整理一下这周的计划：周一上午先把季度报告的初稿写完，下午和设计团队过一遍新版首页的交互稿，重点看一下注册流程是不是太长了；周二要去客户那边开会，记得提前把演示用的数据准备好，顺便确认一下合同里关于交付时间的那一条；周三和周四留给写代码，把上周说的那个同步问题修掉，再补上单元测试；周五下午团队周会，我想讨论一下下个月的招聘计划，还有年底团建去哪里比较合适，另外提醒我周五之前把报销单交了，不然这个月又赶不上了。"
    private static var long: String {
        let chars = Array(longWords)
        let parts = (1...14).map { String(chars.prefix(chars.count * $0 / 14)) }
        return parts.joined(separator: "|") + "=>" + longWords
    }

    // MARK: send

    @MainActor
    func testSendShortWordsLandAtTheTop() throws {
        let (app, log) = hold(Self.short, seconds: 3)
        let down = try waitDown(log, "send")
        let turns = log.lines(containing: ["[turn]"])
        report(log)
        // The message sits at the top of the view (12 pt below it) and the list is on the end.
        let last = try XCTUnwrap(turns.last, "no [turn] lines")
        let y = AppLog.number(before: "pt below the top", in: last) ?? -999
        XCTAssertLessThanOrEqual(abs(y - 12), 2, "the sent message isn't at the top: \(last)")
        XCTAssertTrue(last.hasSuffix("following"), "not following the end: \(last)")
        XCTAssertEqual(AppLog.number(before: "pt from the end", in: down), 0, "the list was left off the end: \(down)")
        XCTAssertEqual(AppLog.number(before: "characters", in: down), 0, "the composer kept something: \(down)")
        XCTAssertEqual(log.count("[voice] exit send: the message had no place"), 0, "the words didn't fly into the message")
        // The final words are the message's.
        XCTAssertTrue(app.staticTexts["今天天气怎么样？"].waitForExistence(timeout: 3), "the message doesn't have the final words")
        assertFrames(log)
        assertNoVoiceLeft(app)
    }

    @MainActor
    func testSendLongDictationLandsWhole() throws {
        let (app, log) = hold(Self.long, seconds: 8, extra: ["-voiceDrillStep", "0.5"])
        let down = try waitDown(log, "send")
        report(log)
        let place = try XCTUnwrap(log.lines(containing: ["[voice] exit send: the message is at y"]).last)
        // A long message: still at the top (it fits on the screen).
        XCTAssertEqual(AppLog.number(before: "pt tall", in: place).map { $0 > 200 }, true, "not a long message: \(place)")
        let last = try XCTUnwrap(log.lines(containing: ["[turn]"]).last, "no [turn] lines")
        XCTAssertLessThanOrEqual(abs((AppLog.number(before: "pt below the top", in: last) ?? -999) - 12), 2, "not at the top: \(last)")
        XCTAssertEqual(AppLog.number(before: "pt from the end", in: down), 0, "the list was left off the end: \(down)")
        assertFrames(log)
        assertNoVoiceLeft(app)
    }

    /// While a reply is being written (the long demo's, from 4 s in): sent,
    /// and once everything is written, the list follows the end.
    @MainActor
    func testSendWhileAReplyIsWritten() throws {
        let (app, log) = hold(Self.short, seconds: 2.5, streaming: true)
        _ = try waitDown(log, "send")
        XCTAssertTrue(log.wait(timeout: 30) { $0.count("[reveal] reply done") >= 2 }, "the replies never finished")
        sleep(2)
        report(log)
        let last = try XCTUnwrap(log.lines(containing: ["[turn]"]).last, "no [turn] lines")
        XCTAssertEqual(AppLog.number(before: "pt from the end", in: last), 0, "not on the end: \(last)")
        XCTAssertTrue(last.hasSuffix("following"), "not following the end: \(last)")
        XCTAssertEqual(log.count("→ detached"), 0, "let go of the end: \(log.lines(containing: ["→ detached"]))")
        XCTAssertTrue(app.staticTexts["今天天气怎么样？"].exists, "the message isn't in the conversation")
        assertNoVoiceLeft(app)
    }

    // MARK: not sent

    @MainActor
    func testCancelLeavesNothing() throws {
        let (app, log) = hold("算了|算了不用了=>算了不用了", seconds: 3, extra: ["-voiceDrillTarget", "cancel"])
        let down = try waitDown(log, "cancel")
        report(log)
        XCTAssertEqual(log.count("[turn]"), 0, "something was sent")
        XCTAssertEqual(AppLog.number(before: "characters", in: down), 0, "the composer has the words: \(down)")
        XCTAssertEqual(AppLog.number(before: "pt from the end", in: down), 0, "the list moved off the end: \(down)")
        XCTAssertFalse(app.staticTexts["算了不用了"].exists, "the words are still on screen")
        assertFrames(log)
        assertNoVoiceLeft(app)
    }

    @MainActor
    func testEditPutsTheFinalWordsInTheComposer() throws {
        let (app, log) = hold("明天|明天提醒我|明天提醒我交报销单=>明天提醒我交报销单。", seconds: 3, extra: ["-voiceDrillTarget", "edit"])
        let down = try waitDown(log, "edit")
        sleep(1) // the final words come after the words have landed
        report(log)
        XCTAssertEqual(log.count("[turn]"), 0, "something was sent")
        XCTAssertEqual(AppLog.number(before: "pt from the end", in: down), 0, "the list moved off the end: \(down)")
        let field = app.descendants(matching: .any)["composerField"]
        XCTAssertEqual(field.value as? String, "明天提醒我交报销单。", "the composer doesn't have the final words")
        assertFrames(log)
        assertNoVoiceLeft(app)
    }

    @MainActor
    func testNothingHeardSaysSoAndSendsNothing() throws {
        let (app, log) = hold("=>", seconds: 2, extra: ["-voiceDrillFinalMs", "700"])
        let down = try waitDown(log, "unheard")
        report(log)
        XCTAssertEqual(log.count("[voice] exit unheard: 3 characters"), 1, "没听清 wasn't shown")
        XCTAssertEqual(log.count("[turn]"), 0, "something was sent")
        XCTAssertEqual(AppLog.number(before: "characters", in: down), 0, "the composer has something: \(down)")
        XCTAssertEqual(AppLog.number(before: "pt from the end", in: down), 0, "the list moved off the end: \(down)")
        assertNoVoiceLeft(app)
    }

    // MARK: helpers

    /// Launches on the long demo conversation and holds to talk 5 s in, with
    /// these words. `streaming`: the demo's long reply is being written
    /// (from 4 s in); otherwise it waits until much later.
    @MainActor
    private func hold(_ words: String, seconds: Double, streaming: Bool = false, extra: [String] = []) -> (XCUIApplication, AppLog) {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES", "-demoState", "long", "-turnTrace", "YES", "-frameTrace", "YES",
                                "-voiceDrill", "\(seconds)", "-voiceDrillDelay", "5", "-voiceDrillText", words]
            + (streaming ? [] : ["-demoStreamDelay", "600"]) + extra
        if let more = ProcessInfo.processInfo.environment["STRESS_ARGS"] {
            app.launchArguments += more.split(separator: " ").map(String.init)
        }
        app.launch()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 20), "the conversation never appeared")
        return (app, AppLog())
    }

    /// Waits for the voice UI to come down after `exit`; returns that line.
    @MainActor
    private func waitDown(_ log: AppLog, _ exit: String) throws -> String {
        XCTAssertTrue(log.wait(timeout: 40) { $0.count("[voice] down after \(exit)") > 0 }, "the words never left (\(exit))")
        return try XCTUnwrap(log.lines(containing: ["[voice] down after \(exit)"]).last)
    }

    /// From the release until the words are gone: no frame over 33 ms after
    /// the first (the release's own, which also lays out the message). Under
    /// XCUITest the accessibility runtime is on and every view coming down
    /// costs more (the same runs without it: VoiceFrames lines in the
    /// scripted measurement); `VOICE_FRAME_BUDGET` sets it (default 34).
    static var frameBudget: Int {
        Int(ProcessInfo.processInfo.environment["VOICE_FRAME_BUDGET"] ?? "") ?? 34
    }

    @MainActor
    private func assertFrames(_ log: AppLog, file: StaticString = #filePath, line: UInt = #line) {
        guard let frames = log.lines(containing: ["later worst"]).last,
              let r = frames.range(of: #"later worst \d+ ms"#, options: .regularExpression) else {
            return XCTFail("no [frames] voice line", file: file, line: line)
        }
        let worst = Int(frames[r].split(separator: " ")[2]) ?? 999
        XCTAssertLessThanOrEqual(worst, Self.frameBudget, "a frame of \(worst) ms after the first: \(frames)", file: file, line: line)
    }

    /// No scrim, words or zones left on screen.
    @MainActor
    private func assertNoVoiceLeft(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.descendants(matching: .any)["voiceWords"].exists, "the words are still up", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '正在听你说话'")).firstMatch.exists,
                       "the zones are still up", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    private func report(_ log: AppLog) {
        let lines = log.lines(containing: ["[voice]", "[turn]", "[frames] voice", "[scroll]", "[drill]"]).suffix(80)
        add(XCTAttachment(string: lines.joined(separator: "\n")))
        print("---- app log\n\(lines.joined(separator: "\n"))")
    }
}
