import XCTest

/// Allies (allies-prd §5) against the demo host on an iPhone simulator, with
/// real taps: the draft card's 发送 and 改一下 in the conversation
/// (`-demoState allies`: an Ally's message, then a draft back), and an Ally's
/// page in 「它」 with 解除 confirmed in place.
final class AlliesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSendingTheDraftShowsItsStateAsItGoes() throws {
        let app = launch(["-demoState", "allies"])
        XCTAssertTrue(app.staticTexts["家人的助理"].waitForExistence(timeout: 15), "no label on the Ally's words")
        let send = app.buttons["发送"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10), "no 发送 on the draft card")
        send.tap()
        // Online: delivered, then seen, and the buttons are gone.
        XCTAssertTrue(app.staticTexts["对方已看到"].waitForExistence(timeout: 15), "the card never said it was seen")
        XCTAssertFalse(app.buttons["改一下"].exists)
        XCTAssertFalse(app.buttons["不发"].exists)
    }

    @MainActor
    func testEditingInPlaceSendsTheNewWords() throws {
        let app = launch(["-demoState", "allies"])
        let edit = app.buttons["改一下"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        // The card's own field, holding the draft's words.
        let field = app.descendants(matching: .any).matching(identifier: "ally-draft-text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field to edit the words in")
        // Into the field at the end of its words, then replace them.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        field.typeText("周六下午三点见")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["周六下午三点见"].waitForExistence(timeout: 10), "the card doesn't show the new words")
        XCTAssertTrue(app.staticTexts["对方已看到"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testRemovingAnAllyAsksInPlaceThenTakesThemOff() throws {
        let app = launch(["-demoScreen", "allies"])
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "路上小心")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no row for 家人")
        row.tap()
        XCTAssertTrue(app.staticTexts["来往记录"].waitForExistence(timeout: 5))
        let remove = app.buttons["解除"].firstMatch
        for _ in 0..<6 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        // In the page, not a dialog: the explanation and two buttons.
        XCTAssertTrue(app.buttons["算了"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["解除"].firstMatch.tap()
        // Back on the list, without them.
        XCTAssertTrue(app.staticTexts["Allies"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "路上小心")).firstMatch.exists)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "小林")).firstMatch.exists)
    }

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES"] + args
        app.launch()
        return app
    }
}
