import XCTest

/// The app follows the device language: launched in English it speaks English
/// (the other UI tests run in Chinese, which is the development language).
final class LocalizationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishConversationAndDetails() throws {
        let app = launch()
        let orb = app.buttons["title-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15), "no orb: not the assistant's conversation")
        XCTAssertTrue(app.buttons["Right pane"].firstMatch.exists, "the 右侧栏 button isn't Right pane")
        XCTAssertFalse(app.buttons["右侧栏"].exists, "still Chinese")
        orb.tap()
        // The assistant's details: 设置 is one of its tiles.
        let detail = app.descendants(matching: .any)["agent-detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the details didn't open")
        let settings = app.descendants(matching: .any)["detail-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3) && settings.isHittable, "no Settings among the tiles")
        XCTAssertTrue(settings.label.contains("Settings"), "the details aren't in English: \(settings.label)")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "设置")).firstMatch.exists, "still Chinese")
    }

    @MainActor
    func testEnglishList() throws {
        let app = launch(["-demoScreen", "list"])
        XCTAssertTrue(app.staticTexts["Agents"].waitForExistence(timeout: 15), "the agent header isn't Agents")
        XCTAssertTrue(app.staticTexts["Workspaces"].exists, "the workspace header isn't Workspaces")
        // The host's other Claude Code sessions are agents like the rest, with no button of their own.
        XCTAssertTrue(app.descendants(matching: .any)["row-session-cc-login"].firstMatch.exists, "no terminal session in the list")
        XCTAssertTrue(app.descendants(matching: .any)["row-archive"].firstMatch.exists, "no Archived row")
    }

    @MainActor
    func testEnglishLibraryTab() throws {
        let app = launch()
        let pane = app.buttons["Right pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 15))
        // Open already on a Mac's demo window; a phone opens it as a page.
        if !app.descendants(matching: .any)["right-pane"].firstMatch.exists { pane.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["right-pane"].firstMatch.waitForExistence(timeout: 5), "the pane didn't open")
        // Its fixed tabs: Waiting · Library · Backlog · Files.
        for tab in ["Waiting", "Library", "Backlog", "Files"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", tab)).firstMatch.exists, "no \(tab) tab")
        }
    }

    @MainActor
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-demo", "YES"] + args
        app.launch()
        return app
    }
}
