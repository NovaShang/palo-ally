import XCTest

/// Allies (allies-prd §5, §11) against the demo host on an iPhone simulator,
/// with real taps: the draft card's 发送 and 改一下 in the assistant's
/// conversation (`-demoState allies`: an Ally's message, then a draft back);
/// an Ally's page from the list, where the owner's words go straight out,
/// ⋯ changes the trust level and 解除 is confirmed in place.
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
        let app = launch(["-demoScreen", "list"])
        let row = app.descendants(matching: .any)["row-ally-al-family"]
        // Below the Pals (asleep ones too): the list scrolls to it.
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 15), "not on the list")
        for _ in 0..<4 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no row for 家人")
        row.tap()
        let more = app.buttons["ally-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no ⋯ on the Ally's page")
        more.tap()
        app.buttons["解除"].firstMatch.tap()
        // In the page, not a dialog: the explanation and two buttons.
        XCTAssertTrue(app.buttons["算了"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["解除"].firstMatch.tap()
        // Back on the list, without them.
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 10) || app.staticTexts["Allies"].exists, "not back on the list")
        let lin = app.descendants(matching: .any)["row-ally-al-lin"]
        for _ in 0..<4 where !lin.exists { app.swipeUp() }
        XCTAssertTrue(lin.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Allies"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["row-ally-al-family"].exists)
    }

    /// The owner's own words on an Ally's page go out as they are: no draft
    /// card, their state under them, and the other side answers.
    @MainActor
    func testOwnWordsOnAnAllysPageGoStraightOut() throws {
        let app = launch(["-demoScreen", "ally", "-demoAlly", "al-family"])
        let field = app.descendants(matching: .any)["ally-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no input on the Ally's page")
        // The assistant's words for the owner say so.
        XCTAssertTrue(app.staticTexts["Palo 代你说"].firstMatch.exists, "the assistant's words aren't marked")
        field.tap()
        field.typeText("今晚吃面")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["今晚吃面"].waitForExistence(timeout: 5), "the words don't show")
        XCTAssertFalse(app.buttons["改一下"].exists, "a card where none should be")
        XCTAssertTrue(app.staticTexts["对方已看到"].waitForExistence(timeout: 15), "no state under the words")
        XCTAssertTrue(app.staticTexts["好的，收到。"].waitForExistence(timeout: 10), "their answer didn't come")
    }

    /// ⋯ changes how the owner's assistant answers them, and the page says it.
    @MainActor
    func testTheTrustLevelChangesFromTheMenu() throws {
        let app = launch(["-demoScreen", "ally", "-demoAlly", "al-family"])
        let note = app.descendants(matching: .any)["ally-trust"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertTrue(note.label.contains("直接回"), note.label)
        app.buttons["ally-menu"].firstMatch.tap()
        app.buttons["每句要你看"].firstMatch.tap()
        let changed = NSPredicate(format: "label CONTAINS %@", "都先给你看")
        expectation(for: changed, evaluatedWith: note)
        waitForExpectations(timeout: 10)
    }

    /// An invite opened from outside (`-pairLink` goes through the same
    /// handler as the system Camera's open): confirm with 我的, then they're
    /// on the list with that tag.
    @MainActor
    func testAcceptingAnInviteAddsThemWithTheirTag() throws {
        var c = URLComponents()
        c.scheme = "paloally"
        c.host = "ally"
        c.queryItems = [
            URLQueryItem(name: "relay", value: "https://relay.example.com"),
            URLQueryItem(name: "daemon", value: "demo-other"),
            URLQueryItem(name: "code", value: "135790"),
            URLQueryItem(name: "hostkey", value: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"),
            URLQueryItem(name: "name", value: "小周"),
            URLQueryItem(name: "exp", value: String(Int64(Date().timeIntervalSince1970 * 1000) + 600_000)),
        ]
        let app = launch(["-pairLink", c.url!.absoluteString])
        XCTAssertTrue(app.staticTexts["加「小周的助理」为 Ally？"].waitForExistence(timeout: 15), "no confirm sheet")
        app.buttons["我的"].tap()
        app.buttons["加为 Ally"].tap()
        XCTAssertTrue(app.staticTexts["加好了"].waitForExistence(timeout: 15), "never said it was added")
        app.buttons["完成"].tap()
        // Back to the list: they're under Allies.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                                       "row-ally-", "小周")).firstMatch
        // The list runs past the screen: the newest Ally is further down.
        XCTAssertTrue(app.staticTexts["Allies"].waitForExistence(timeout: 10) || app.staticTexts["Pals"].exists, "not back on the list")
        for _ in 0..<4 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "not on the list")
        XCTAssertTrue(row.label.contains("我的"), "tag missing: \(row.label)")
    }

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"] + args
        app.launch()
        return app
    }
}
