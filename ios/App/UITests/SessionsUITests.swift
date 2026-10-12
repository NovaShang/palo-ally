import XCTest

/// Pals (pals-prd §4, §6) and the computer's other sessions against the demo
/// host on an iPhone simulator, with real taps: words typed on a Pal's page
/// land in its conversation and it answers; 交还终端 and 移出 Pals are asked
/// in the page; a proposal's 开吧 opens a Pal whose page opens from the card;
/// a Pal's card is on its own page, another session's in the assistant's
/// conversation, and each goes once answered.
final class SessionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWordsTypedOnAPalsPageLandInItsConversation() throws {
        // The composer's keyboard comes up a few seconds in (`-demoKeyboard`):
        // a tap on it would first ask for the microphone in the simulator.
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-notes", "-demoKeyboard", "4:600"])
        XCTAssertTrue(app.navigationBars.staticTexts["笔记整理"].waitForExistence(timeout: 15), "the Pal's page didn't open")
        XCTAssertTrue(app.buttons["按住说话，轻点打字"].firstMatch.exists, "no composer on the Pal's page")
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.typeText("把上周的也归一下")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(text(app, "把上周的也归一下").waitForExistence(timeout: 5), "the words don't show")
        // It streams its answer, the way the assistant's do.
        XCTAssertTrue(text(app, "好的，按你说的办").waitForExistence(timeout: 15), "the Pal never answered")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "把上周的也归一下")).count, 1)
    }

    @MainActor
    func testHandingBackShowsTheLineAndRemovingAsksInThePage() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-notes"])
        let more = app.buttons["pal-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "no ⋯ on a Pal's page")
        more.tap()
        app.buttons["交还终端"].firstMatch.tap()
        // Asked in the page, not a dialog.
        XCTAssertTrue(app.buttons["算了"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["交还"].firstMatch.tap()
        let line = app.staticTexts["resume-command"]
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no line to resume it in a terminal")
        XCTAssertTrue(line.label.hasPrefix("claude --resume "), line.label)
        XCTAssertTrue(app.buttons["复制这一行"].exists)
        // Closing it goes back to the list, without that Pal.
        app.buttons["关上"].tap()
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["row-pal-pal-notes"].exists)

        // 移出 Pals, on the other one.
        app.descendants(matching: .any)["row-pal-pal-site"].tap()
        let menu = app.buttons["pal-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["移出 Pals"].firstMatch.tap()
        XCTAssertTrue(app.buttons["算了"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["移出"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["row-pal-pal-site"].exists)
    }

    @MainActor
    func testYesToAProposalOpensAPalWhosePageOpensFromTheCard() throws {
        let app = launch(["-demoState", "helper"])
        let yes = app.buttons["开吧"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 15), "no 开吧 on the proposal")
        yes.tap()
        XCTAssertTrue(app.staticTexts["已经开了"].waitForExistence(timeout: 10), "the card never said it started")
        XCTAssertFalse(app.buttons["不用"].exists)
        app.buttons["去看看它"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["报销帮手"].waitForExistence(timeout: 10), "the Pal's page didn't open")
        // The assistant's handover is its first words there.
        XCTAssertTrue(text(app, "Palo 说").waitForExistence(timeout: 10), "the assistant's words aren't marked")
    }

    @MainActor
    func testEachCardWaitsWhereItBelongsAndGoesOnceAnswered() throws {
        let app = launch(["-demoState", "sessions"])
        // Another session's question: in the assistant's conversation.
        let asks = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "问卷数据清洗 问你")).firstMatch
        XCTAssertTrue(asks.waitForExistence(timeout: 15), "no source on the session's card")
        // The Pal's card isn't here.
        XCTAssertFalse(text(app, "npm run build").exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "B 用中位数补上")).firstMatch.tap()
        app.buttons["发送"].firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: asks)
        waitForExpectations(timeout: 10)

        // The Pal's card: on its page, with its count on the list.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any)["row-pal-pal-site"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("1 件等你"), row.label)
        row.tap()
        let allow = app.buttons["允许"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "the Pal's card isn't on its page")
        allow.tap()
        XCTAssertTrue(text(app, "构建通过了").waitForExistence(timeout: 15), "it didn't carry on")
        XCTAssertFalse(app.buttons["允许"].exists)
    }

    // MARK: -

    @MainActor
    private func text(_ app: XCUIApplication, _ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch
    }

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES"] + args
        app.launch()
        return app
    }
}
