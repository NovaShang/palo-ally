import XCTest

/// The app follows the device language: launched in English it speaks English
/// (the other UI tests run in Chinese, which is the development language).
final class LocalizationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishConversationAndManagement() throws {
        let app = launch()
        let orb = app.buttons["title-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15), "no orb: not the assistant's conversation")
        XCTAssertTrue(app.buttons["Library"].exists, "the 成果 button isn't Library")
        XCTAssertFalse(app.buttons["成果"].exists, "still Chinese")
        orb.tap()
        XCTAssertTrue(app.buttons["Goals"].waitForExistence(timeout: 5), "management isn't in English")
        XCTAssertTrue(app.buttons["Memory"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    @MainActor
    func testEnglishListAndLibrary() throws {
        let app = launch(["-demoScreen", "list"])
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["adopt-cc-login"].exists)
        XCTAssertEqual(app.buttons["adopt-cc-login"].label, "Take over")
    }

    @MainActor
    func testEnglishLibraryPage() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 15))
        app.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Library"].waitForExistence(timeout: 5), "the Library page isn't titled Library")
        XCTAssertTrue(app.staticTexts["Pin"].exists || app.staticTexts["Recently updated"].exists, "no English section titles")
    }

    @MainActor
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-demo", "YES"] + args
        app.launch()
        return app
    }
}
