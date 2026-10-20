import XCTest

/// The basics on an iPhone, walked before any build reaches the owner:
/// Palo's page and a session's have the round indicator as their title and
/// the same right-pane button; the indicator opens the details; the button
/// opens the pane; the composer takes typing; the list opens Palo and a
/// session. In dark and in light. Each step attaches a screenshot.
final class PhoneSmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testBasicsDark() throws { try walk("dark") }
    @MainActor func testBasicsLight() throws { try walk("light") }

    @MainActor
    private func walk(_ look: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES", "-demoAppearance", look]
        app.launch()
        defer { app.terminate() }

        // Palo's page: the indicator and the pane button.
        let palo = app.buttons["title-orb"]
        XCTAssertTrue(palo.waitForExistence(timeout: 20), "Palo's page has no indicator")
        XCTAssertTrue(app.buttons["page-files"].exists, "Palo's page has no right-pane button")
        sleep(1)
        shot(app, "\(look)-1-palo")
        type(app, "测试")
        shot(app, "\(look)-2-palo-typed")
        dismissKeyboard(app)

        // Its details.
        palo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent-detail"].waitForExistence(timeout: 5), "Palo's details didn't open")
        sleep(1)
        shot(app, "\(look)-3-palo-details")
        // Pulled up to the full height: the rest of it.
        app.descendants(matching: .any)["agent-detail"].firstMatch.swipeUp()
        sleep(1)
        shot(app, "\(look)-3b-palo-details-full")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(palo.waitForExistence(timeout: 5))

        // The pane.
        app.buttons["page-files"].tap()
        sleep(2)
        shot(app, "\(look)-4-palo-pane")
        let close = app.buttons["关闭侧栏"].firstMatch
        XCTAssertTrue(close.exists, "the pane has no close button")
        close.tap()
        XCTAssertTrue(palo.waitForExistence(timeout: 5), "closing the pane didn't return to Palo")

        // The list, then a session.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let site = app.descendants(matching: .any)["row-pal-pal-notes"].firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5), "no 笔记整理 in the list")
        shot(app, "\(look)-5-list")
        site.tap()
        let session = app.buttons["title-capsule"]
        XCTAssertTrue(session.waitForExistence(timeout: 5), "the session's page has no indicator")
        XCTAssertTrue(app.buttons["page-files"].exists, "the session's page has no right-pane button")
        sleep(1)
        shot(app, "\(look)-6-session")
        session.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent-detail"].waitForExistence(timeout: 5), "the session's details didn't open")
        sleep(1)
        shot(app, "\(look)-7-session-details")
        // Pulled up to the full height: the rest of it.
        app.descendants(matching: .any)["agent-detail"].firstMatch.swipeUp()
        sleep(1)
        shot(app, "\(look)-7b-session-details-full")
        app.buttons["完成"].firstMatch.tap()

        // Back to the list and into Palo again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let paloRow = app.descendants(matching: .any)["row-palo"].firstMatch
        XCTAssertTrue(paloRow.waitForExistence(timeout: 5))
        paloRow.tap()
        XCTAssertTrue(palo.waitForExistence(timeout: 5), "Palo didn't open from the list")
    }

    /// Taps the composer and types; the text must land in it.
    @MainActor
    private func type(_ app: XCUIApplication, _ text: String) {
        let press = app.buttons["按住说话，轻点打字"].firstMatch
        XCTAssertTrue(press.waitForExistence(timeout: 5), "no composer")
        press.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping the composer brought no keyboard")
        sleep(1)
        app.typeText(text)
        let typed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'composerField' AND value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 3), "typing didn't reach the composer")
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        // Clear the draft, then put the keyboard away by tapping the conversation.
        for _ in 0..<4 { app.keys["delete"].firstMatch.tap() }
        app.swipeDown()
        sleep(1)
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
