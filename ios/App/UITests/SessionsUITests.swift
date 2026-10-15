import XCTest

/// Pals (pals-prd §4, §6) and the computer's other sessions against the demo
/// host on an iPhone simulator, with real taps: words typed on a Pal's page
/// land in its conversation and it answers; 交还终端 and 移出 Pals are asked
/// in the page; a proposal's 开吧 opens a Pal whose page opens from the card;
/// a Pal's card is on its own page, another session's in the assistant's
/// conversation, and each goes once answered; the assistant's card proposing
/// to take over a conversation that ended does so only on 接管.
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

    /// An asleep Pal (pals-prd §12): its history is there; words for it say
    /// 「正在叫醒…」 until it's up, then it answers; back on the list it's awake.
    @MainActor
    func testWordsForAnAsleepPalWakeItAndItAnswers() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-blog", "-demoKeyboard", "4:600", "-demoWakeAfter", "6"])
        XCTAssertTrue(app.navigationBars.staticTexts["博客改版"].waitForExistence(timeout: 15), "the Pal's page didn't open")
        XCTAssertTrue(text(app, "评论区的样式改好了").waitForExistence(timeout: 10), "its history isn't there")
        XCTAssertTrue(text(app, "睡着 · 上次叫醒约 $0.04").exists, "the page doesn't say it's asleep")
        attach(app, "asleep-pal")
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.typeText("评论区再加个点赞")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(text(app, "正在叫醒").waitForExistence(timeout: 5), "no 正在叫醒 while it wakes")
        attach(app, "waking-pal")
        XCTAssertTrue(text(app, "好的，按你说的办").waitForExistence(timeout: 20), "the woken Pal never answered")
        XCTAssertFalse(text(app, "正在叫醒").exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "评论区再加个点赞")).count, 1)
        // Back on the list: awake now; the other one still asleep, after the awake ones.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 10))
        let blog = app.descendants(matching: .any)["row-pal-pal-blog"]
        let photos = app.descendants(matching: .any)["row-pal-pal-photos"]
        XCTAssertTrue(blog.waitForExistence(timeout: 5) && photos.exists)
        XCTAssertFalse(blog.label.contains("睡着"), "it still shows asleep")
        XCTAssertTrue(photos.label.contains("睡着"), "the asleep one doesn't say so")
        XCTAssertLessThan(blog.frame.minY, photos.frame.minY)
        attach(app, "list-after-wake")
    }

    /// 重命名 (pals-prd §13): from the page's ⋯ and from the row's menu on
    /// the list, the system's alert with the name filled in.
    @MainActor
    func testRenamingAPalFromItsPageAndFromTheList() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-notes"])
        let more = app.buttons["pal-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "no ⋯ on a Pal's page")
        more.tap()
        app.buttons["重命名"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no name field")
        XCTAssertEqual(field.value as? String, "笔记整理", "not filled in")
        attach(app, "rename-alert")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        field.typeText("读书笔记")
        app.alerts.buttons["好"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["读书笔记"].waitForExistence(timeout: 5), "the page's title didn't change")
        // From the list: the row's menu.
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.descendants(matching: .any)["row-pal-pal-site"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["row-pal-pal-notes"].label.contains("读书笔记"))
        row.press(forDuration: 1.0)
        app.buttons["重命名"].firstMatch.tap()
        let again = app.alerts.textFields.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.value as? String, "网站帮手")
        again.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        again.typeText("官网")
        app.alerts.buttons["好"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "官网"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
    }

    /// A reply has no buttons under it: 拷贝整条 / 回复 are in its text's
    /// menu (long press), with the selection's own items; 回复 quotes it.
    /// Light and dark.
    @MainActor
    func testAReplysCopyAndReplyAreInItsMenu() throws {
        for look in ["light", "dark"] {
            let app = launch(["-demoScreen", "pal", "-demoPal", "pal-notes", "-demoAppearance", look])
            XCTAssertTrue(app.navigationBars.staticTexts["笔记整理"].waitForExistence(timeout: 15), "the Pal's page didn't open")
            let reply = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "12 篇笔记都归好类了")).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 10), "no reply")
            XCTAssertFalse(app.buttons["复制这条回答"].exists, "a copy button under the reply")
            XCTAssertFalse(app.buttons["回复这条"].exists, "a reply button under the reply")
            attach(app, "reply-\(look)")
            reply.press(forDuration: 1.0)
            XCTAssertTrue(app.menuItems["拷贝整条"].waitForExistence(timeout: 5) || app.buttons["拷贝整条"].exists, "no 拷贝整条 in the menu")
            attach(app, "reply-menu-\(look)")
            (app.menuItems["回复"].exists ? app.menuItems["回复"] : app.buttons["回复"]).firstMatch.tap()
            // 回复: the answer is quoted over the composer.
            XCTAssertTrue(app.buttons["不回复了"].firstMatch.waitForExistence(timeout: 5), "回复 quoted nothing")
            attach(app, "reply-quoted-\(look)")
            app.terminate()
        }
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
        XCTAssertTrue(line.label.contains("claude --resume "), line.label)
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

    /// The assistant's pal_adopt card (pals-prd §10): nothing until 接管,
    /// then 已经接过来了 and the Pal's page from the card.
    @MainActor
    func testTheAssistantsAdoptCardTakesItOverOnYes() throws {
        let app = launch(["-demoState", "adopt"])
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "pal-adopt-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "no card")
        XCTAssertTrue(text(app, "接管「首页改成两栏布局」").exists, "the card doesn't say what")
        XCTAssertTrue(text(app, "~/code/site").exists, "the card doesn't say where")
        app.buttons["接管"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已经接过来了"].waitForExistence(timeout: 10), "the card never said it was taken over")
        XCTAssertFalse(app.buttons["不用"].exists)
        attach(app, "card-adopted")
        app.buttons["去看看它"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["首页改成两栏布局"].waitForExistence(timeout: 10), "the Pal's page didn't open")
    }

    @MainActor
    func testNoToTheAdoptCardTakesNothingOver() throws {
        let app = launch(["-demoState", "adopt"])
        let no = app.buttons["不用"].firstMatch
        XCTAssertTrue(no.waitForExistence(timeout: 15))
        no.tap()
        XCTAssertTrue(app.staticTexts["没接"].waitForExistence(timeout: 10), "the card never said no")
        XCTAssertFalse(app.buttons["接管"].exists)
        attach(app, "card-discarded")
    }

    /// The computer couldn't take it over: the card says why and stays on offer.
    @MainActor
    func testAnAdoptCardThatFailsSaysWhyAndStaysOnOffer() throws {
        let app = launch(["-demoState", "adopt", "-demoAdoptError", "有别的进程开着它"])
        let yes = app.buttons["接管"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 15))
        yes.tap()
        XCTAssertTrue(text(app, "没接成：有别的进程开着它").waitForExistence(timeout: 10), "no reason given")
        XCTAssertTrue(app.buttons["接管"].firstMatch.isEnabled, "not on offer again")
        XCTAssertFalse(app.staticTexts["已经接过来了"].exists)
        attach(app, "card-failed")
    }

    // MARK: -

    /// A long message the assistant sent a Pal folds to its first lines with
    /// 展开全部; tapped, all of it shows with 收起, growing down from where it
    /// was. Another session's long message stays folded.
    @MainActor
    func testALongMessageFromTheAssistantFoldsAndUnfolds() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-notes"])
        XCTAssertTrue(app.navigationBars.staticTexts["笔记整理"].waitForExistence(timeout: 15), "the Pal's page didn't open")
        let brief = text(app, "主人想让这周的笔记整理多做几件事")
        XCTAssertTrue(brief.waitForExistence(timeout: 10), "no long message from the assistant")
        let unfold = app.buttons.matching(NSPredicate(format: "label == %@", "展开全部"))
        XCTAssertEqual(unfold.count, 2, "both long messages from other agents should fold")
        if !unfold.element(boundBy: 0).isHittable { app.swipeDown() }
        let folded = brief.frame
        let button = unfold.element(boundBy: 0)
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThan(button.frame.minY, folded.minY, "展开全部 isn't under the message")
        attach(app, "folded")
        button.tap()

        let fold = app.buttons["收起"]
        XCTAssertTrue(fold.waitForExistence(timeout: 5), "no 收起 once unfolded")
        XCTAssertEqual(unfold.count, 1, "the other long message should stay folded")
        // All of it: much taller, from the same place.
        let whole = brief.frame
        XCTAssertGreaterThan(whole.height, folded.height * 1.8, "it didn't unfold")
        XCTAssertEqual(whole.minY, folded.minY, accuracy: 2, "unfolding moved the message")
        attach(app, "unfolded")

        fold.tap()
        XCTAssertTrue(unfold.element(boundBy: 1).waitForExistence(timeout: 5), "收起 didn't fold it again")
        XCTAssertEqual(brief.frame.height, folded.height, accuracy: 2)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

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
