import XCTest

/// Claude 用量 (docs/workbench-design/usage.html) against the demo host on an
/// iPhone simulator, with real taps: its row in the list, an agent that
/// stopped for a used-up limit opened from the page, the rest of a long list
/// of them, 换个账号 asked in place and put away, the sign-in sheet and its 取消.
final class UsageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheRowOpensThePageAndAStoppedAgentOpensFromIt() throws {
        let app = launch("usageHit")
        openPage(app)
        XCTAssertTrue(text(app, "停在这里").waitForExistence(timeout: 5), "nothing says what stopped")
        let site = app.descendants(matching: .any)["usage-stopped-pal-site"].firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5), "no row for 网站帮手")
        site.tap()
        // Its conversation, where the limit said so.
        XCTAssertTrue(text(app, "到点我自己接着做").waitForExistence(timeout: 10), "its conversation didn't open")
    }

    @MainActor
    func testTheRestOfThemOpensInPlace() throws {
        let app = launch("usageHitMany")
        openPage(app)
        let last = app.descendants(matching: .any)["usage-stopped-pal-more-9"].firstMatch
        XCTAssertFalse(last.exists, "all of them listed at first")
        let more = app.buttons["usage-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no 还有 N 个")
        XCTAssertTrue(more.label.contains("6"), more.label)
        more.tap()
        for _ in 0..<4 where !last.exists { app.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5), "the rest didn't come")
        XCTAssertFalse(more.exists)
    }

    @MainActor
    func testSwitchingIsAskedInPlaceAndPutAway() throws {
        let app = launch("usage")
        openPage(app)
        tap(app, "usage-switch")
        XCTAssertTrue(app.staticTexts["换一个 Claude 账号？"].waitForExistence(timeout: 5), "not asked")
        // In the page, not a dialog.
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        reveal(app, app.buttons["算了"].firstMatch).tap()
        XCTAssertFalse(app.staticTexts["换一个 Claude 账号？"].waitForExistence(timeout: 2), "still asked")
        // Asked again and gone on with: the sign-in sheet, for another account.
        tap(app, "usage-switch")
        reveal(app, app.buttons["换账号"].firstMatch).tap()
        XCTAssertTrue(app.navigationBars["换个账号"].waitForExistence(timeout: 10), "no sign-in sheet")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Claude 用量"].waitForExistence(timeout: 5), "not back on the page")
    }

    @MainActor
    func testTheSignInSheetOpensWhileTheLoginWorksAndIsCancelled() throws {
        let app = launch("usage")
        openPage(app)
        tap(app, "usage-again")
        XCTAssertTrue(app.navigationBars["重新登录"].waitForExistence(timeout: 10), "no sign-in sheet")
        XCTAssertTrue(text(app, "现在的登录照常用").exists, "it doesn't say the login goes on")
        XCTAssertTrue(app.buttons["打开授权页"].waitForExistence(timeout: 10), "no link")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Claude 用量"].waitForExistence(timeout: 5), "not back on the page")
        // Cancelled: the login is as it was.
        XCTAssertFalse(app.staticTexts["登录过期了"].exists)
    }

    @MainActor
    func testSigningOutIsAskedThenSaysSoAndOffersTheWayBack() throws {
        let app = launch("usage")
        openPage(app)
        tap(app, "usage-logout")
        XCTAssertTrue(app.staticTexts["退出 Claude 登录？"].waitForExistence(timeout: 5), "not asked")
        // The row, then the panel's own button under it.
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "退出登录", "usage-logout"))
        reveal(app, buttons.firstMatch).tap()
        XCTAssertTrue(app.staticTexts["已退出登录"].waitForExistence(timeout: 10), "doesn't say it's signed out")
        XCTAssertTrue(app.buttons["usage-sign-in"].firstMatch.waitForExistence(timeout: 5), "no way back")
        XCTAssertFalse(app.descendants(matching: .any)["usage-switch"].exists)
    }

    // MARK: helpers

    @MainActor
    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-demoScreen", "list", "-demoState", state, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    /// The list's row, below everything else, and the page it opens.
    @MainActor
    private func openPage(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["agent"].waitForExistence(timeout: 15), "not on the list")
        let row = app.descendants(matching: .any)["row-usage"].firstMatch
        reveal(app, row).tap()
        XCTAssertTrue(app.navigationBars["Claude 用量"].waitForExistence(timeout: 10), "the page didn't open")
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ id: String) {
        reveal(app, app.descendants(matching: .any)[id].firstMatch).tap()
    }

    /// Scrolled to, clear of the buttons at the list's foot.
    @MainActor @discardableResult
    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) -> XCUIElement {
        for _ in 0..<6 where !e.exists || !e.isHittable || e.frame.maxY > app.frame.maxY - 110 { app.swipeUp() }
        XCTAssertTrue(e.waitForExistence(timeout: 5), "not there: \(e)")
        return e
    }

    @MainActor
    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }
}
