import XCTest

/// Sessions (sessions-prd §5) against the demo host on an iPhone simulator,
/// with real taps: words typed on a session's page land in its conversation;
/// 停止 is asked in the page and 复活 brings it back; a helper proposal's 开吧
/// starts a helper whose page opens from the card; a session's card at the
/// conversation's end goes once it's answered.
final class SessionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWordsSentFromTheAppLandInTheSession() throws {
        let app = launch(["-demoScreen", "session"])
        let field = app.descendants(matching: .any).matching(identifier: "session-input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no input on the session's page")
        field.tap()
        field.typeText("详情页也一起做了吧")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["详情页也一起做了吧"].waitForExistence(timeout: 5), "the words don't show while they go")
        // In the session's own conversation, then its answer.
        let answer = app.staticTexts["好的，按你说的办。"]
        if !answer.waitForExistence(timeout: 15) { print("---- tree\n\(app.debugDescription)") }
        XCTAssertTrue(answer.exists, "the session never answered")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "详情页也一起做了吧")).count, 1)
    }

    @MainActor
    func testStoppingAsksInThePageAndReviveBringsItBack() throws {
        let app = launch(["-demoScreen", "session", "-demoSession", "cc-notes"])
        let more = app.buttons["更多"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "no ⋯ on a helper's page")
        more.tap()
        app.buttons["停止"].firstMatch.tap()
        // In the page, not a dialog.
        XCTAssertTrue(app.buttons["算了"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["停止"].firstMatch.tap()
        let revive = app.buttons["复活"].firstMatch
        XCTAssertTrue(revive.waitForExistence(timeout: 10), "a stopped helper offers no 复活")
        revive.tap()
        let field = app.descendants(matching: .any).matching(identifier: "session-input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "revived, but no input again")
    }

    @MainActor
    func testYesToAProposalStartsAHelperThatOpensFromTheCard() throws {
        let app = launch(["-demoState", "helper"])
        let yes = app.buttons["开吧"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 15), "no 开吧 on the proposal")
        yes.tap()
        XCTAssertTrue(app.staticTexts["已经开了"].waitForExistence(timeout: 10), "the card never said it started")
        XCTAssertFalse(app.buttons["不用"].exists)
        app.buttons["去看看它"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["报销帮手"].waitForExistence(timeout: 10), "the helper's page didn't open")
    }

    @MainActor
    func testASessionsCardGoesOnceAnswered() throws {
        let app = launch(["-demoState", "sessions"])
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "网站帮手 想运行")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 15), "no source on the session's card")
        let allow = app.buttons["允许"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: label)
        waitForExpectations(timeout: 10)
        // The other session's question is still there.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "问卷数据清洗 问你")).firstMatch.exists)
    }

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES"] + args
        app.launch()
        return app
    }
}
