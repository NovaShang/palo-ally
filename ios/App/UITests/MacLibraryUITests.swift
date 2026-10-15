#if targetEnvironment(macCatalyst)
import XCTest

/// 成果 in the inspector beside the conversation on the Mac: clicking a
/// Markdown item opens it, and ⌘[ goes back to the list. It once did nothing
/// at all: the click only highlighted the row, because the inspector sat in
/// the split view's detail column and its stack was taken for the column's.
///
/// Run like MacScrollWheelUITests (see its header), under another bundle id
/// with `-only-testing:PaloAllyUITests/MacLibraryUITests`; the screen must be
/// unlocked.
final class MacLibraryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAMarkdownItemOpensInTheInspector() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES", "-demoWindow", "1300x850"]
        app.launch()
        defer { app.terminate() }

        let library = app.buttons["成果"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30), "no 成果 in the toolbar")
        library.click()

        let title = NSPredicate(format: "label CONTAINS %@", "每日晨报")
        let row = app.cells.containing(title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "成果 didn't open beside the conversation")
        row.click()

        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 5), "clicking the Markdown item didn't open it")
        let heading = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "今日晨报")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the Markdown wasn't rendered")

        // ⌘[ goes back to the list, still beside the conversation.
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back didn't return to 成果's list")
        XCTAssertFalse(app.buttons["更多"].exists)
    }
}
#endif
