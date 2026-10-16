import XCTest

/// Long quotes fold (展开 / 收起) and a reply's menu reads it aloud (朗读 /
/// 停止朗读), against the demo host. Speech can't be heard here: the app runs
/// with `-speechSilent YES`, so the state flips and nothing is said.
final class ReadAloudUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testALongQuoteFoldsAndOpens() throws {
        let app = launch()
        let toggle = app.buttons["quote-fold-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the long quote has no 展开")
        XCTAssertEqual(toggle.label, "展开")
        // Only the long one folds: the short quote beside it has no control.
        XCTAssertEqual(app.buttons.matching(identifier: "quote-fold-toggle").count, 1)
        attach(app, "quote-folded")
        toggle.tap()
        XCTAssertTrue(app.buttons["收起"].firstMatch.waitForExistence(timeout: 5), "展开 didn't open it")
        attach(app, "quote-open")
        app.buttons["收起"].firstMatch.tap()
        XCTAssertTrue(app.buttons["展开"].firstMatch.waitForExistence(timeout: 5), "收起 didn't fold it")
    }

    @MainActor
    func testTheReplyMenuReadsAloudAndStops() throws {
        let app = launch()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "周末安排", "周末安排")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the reply didn't load")
        for _ in 0..<8 where !reply.isHittable { app.swipeDown(velocity: .slow) }

        reply.press(forDuration: 1.2)
        XCTAssertTrue(item(app, "朗读").waitForExistence(timeout: 5), "no 朗读 in the reply's menu")
        attach(app, "menu-read-aloud")
        item(app, "朗读").tap()

        reply.press(forDuration: 1.2)
        XCTAssertTrue(item(app, "停止朗读").waitForExistence(timeout: 5), "still 朗读 while reading")
        attach(app, "menu-stop-reading")
        item(app, "停止朗读").tap()

        reply.press(forDuration: 1.2)
        XCTAssertTrue(item(app, "朗读").waitForExistence(timeout: 5), "still 停止朗读 after stopping")
    }

    @MainActor
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let i = app.menuItems[title].firstMatch
        return i.exists ? i : app.buttons[title].firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                "-demoState", "longQuote", "-speechSilent", "YES"]
        app.launch()
        return app
    }
}
