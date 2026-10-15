import XCTest

/// Standard navigation (pals-prd §2, §3, §5) against the demo host on an
/// iPhone simulator: the app opens in the assistant's conversation, back is
/// the list, a Pal and an Ally open from it, the orb opens management, 成果
/// is the conversation's toolbar button, 接管 adopts a session in place, and
/// 最近的对话 adopts one that ended.
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchLandsInTheAssistantsConversation() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 15), "no orb: not the assistant's conversation")
        XCTAssertTrue(app.buttons["按住说话，轻点打字"].exists, "no composer")
        XCTAssertTrue(app.buttons["成果"].exists, "no 成果 in the toolbar")
        // The list is one step back, not on screen.
        XCTAssertFalse(app.staticTexts["Pals"].exists)
    }

    @MainActor
    func testBackGoesToTheList() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 15))
        back(app)
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 5), "no Pals section")
        XCTAssertTrue(app.staticTexts["Allies"].exists, "no Allies section")
        XCTAssertTrue(row(app, "row-palo").exists, "no row for the assistant")
        XCTAssertTrue(row(app, "row-pal-pal-site").exists && row(app, "row-pal-pal-notes").exists)
        XCTAssertTrue(app.buttons["adopt-cc-login"].exists, "another session has no 接管")
        XCTAssertTrue(row(app, "row-recent").exists, "no 最近的对话 under Pals")
        // The list runs past the screen: Allies' last row is further down.
        XCTAssertTrue(scrolledTo(app, app.buttons["添加"]), "no 添加 under Allies")
        // And in again.
        app.swipeDown()
        row(app, "row-palo").tap()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAPalOpensFromTheList() throws {
        let app = launch(["-demoScreen", "list"])
        let pal = row(app, "row-pal-pal-site")
        XCTAssertTrue(pal.waitForExistence(timeout: 15))
        pal.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 5), "the Pal's page didn't open")
        XCTAssertTrue(app.buttons["pal-menu"].exists)
        XCTAssertFalse(app.buttons["title-orb"].exists, "a Pal's page has no orb")
        XCTAssertTrue(app.buttons["允许"].firstMatch.waitForExistence(timeout: 5), "its card isn't there")
        back(app)
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAnAllyOpensFromTheList() throws {
        let app = launch(["-demoScreen", "list"])
        let ally = row(app, "row-ally-al-family")
        XCTAssertTrue(ally.waitForExistence(timeout: 15))
        ally.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["家人"].waitForExistence(timeout: 5), "the Ally's page didn't open")
        XCTAssertTrue(app.descendants(matching: .any)["ally-input"].exists)
        XCTAssertTrue(app.staticTexts["路上小心"].exists || app.staticTexts["收到，路上小心。"].exists, "the exchanges aren't there")
    }

    @MainActor
    func testTheOrbOpensManagement() throws {
        let app = launch()
        let orb = app.buttons["title-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15))
        orb.tap()
        XCTAssertTrue(app.buttons["目标"].waitForExistence(timeout: 5), "management didn't open")
        XCTAssertTrue(app.buttons["记忆"].exists, "no 记忆 in management")
        XCTAssertTrue(app.buttons["设置"].exists, "no 设置 in management")
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["设置"].waitForExistence(timeout: 5))
        back(app)
        back(app)
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 5), "not back in the conversation")
    }

    @MainActor
    func testLibraryIsTheConversationsToolbarButton() throws {
        let app = launch()
        let library = app.buttons["成果"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["成果"].waitForExistence(timeout: 5), "成果 didn't open")
        back(app)
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 5))
    }

    /// A Markdown item in 成果 opens rendered, and back is the list again.
    @MainActor
    func testAMarkdownItemOpensFromTheLibrary() throws {
        let app = launch(["-demoScreen", "library"])
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "每日晨报")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no Markdown item in 成果")
        row.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["每日晨报"].waitForExistence(timeout: 5), "the item didn't open")
        let heading = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "今日晨报")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the Markdown wasn't rendered")
        back(app)
        XCTAssertTrue(app.navigationBars.staticTexts["成果"].waitForExistence(timeout: 5), "back didn't return to 成果")
    }

    /// A terminal session: quit it there first. The list says so in place,
    /// then the Pal's page opens by itself once it's done.
    @MainActor
    func testAdoptingATerminalSessionWaitsThenOpensItsPage() throws {
        let app = launch(["-demoScreen", "list", "-demoAdoptAfter", "4"])
        let adopt = app.buttons["adopt-cc-login"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 15))
        adopt.tap()
        XCTAssertTrue(app.staticTexts["请在终端里输入 /exit 退出它，退出后自动接管"].waitForExistence(timeout: 5),
                      "no word on quitting it in the terminal")
        XCTAssertTrue(app.buttons["adopt-cancel-cc-login"].exists, "no 取消")
        XCTAssertTrue(app.navigationBars.staticTexts["修登录跳转"].waitForExistence(timeout: 15), "its page didn't open")
        XCTAssertTrue(app.staticTexts["登录以后会跳回首页，应该回到原来那一页"].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "跳回首页")).firstMatch.exists,
                      "its conversation so far isn't there")
    }

    @MainActor
    func testCancellingTheWaitLeavesItWhereItWas() throws {
        let app = launch(["-demoScreen", "list", "-demoAdoptAfter", "0"])
        let adopt = app.buttons["adopt-cc-login"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 15))
        adopt.tap()
        let cancel = app.buttons["adopt-cancel-cc-login"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.buttons["adopt-cc-login"].waitForExistence(timeout: 5), "接管 didn't come back")
        XCTAssertFalse(app.staticTexts["请在终端里输入 /exit 退出它，退出后自动接管"].exists)
    }

    /// A background session: a moment, then its page.
    @MainActor
    func testAdoptingABackgroundSessionOpensItsPage() throws {
        let app = launch(["-demoScreen", "list"])
        let adopt = app.buttons["adopt-cc-data"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 15))
        adopt.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["问卷数据清洗"].waitForExistence(timeout: 10), "its page didn't open")
        // Its question came with it.
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "B 用中位数补上")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "its question isn't on its page")
    }

    /// 最近的对话 (pals-prd §10): a conversation that ended, asked in its
    /// row, then its Pal's page; back on the list it's a Pal.
    @MainActor
    func testAdoptingARecentConversationOpensItsPage() throws {
        let app = launch(["-demoScreen", "list"])
        let recent = row(app, "row-recent")
        XCTAssertTrue(recent.waitForExistence(timeout: 15), "no 最近的对话 under Pals")
        recent.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["最近的对话"].waitForExistence(timeout: 5), "the page didn't open")
        // By folder, the folder's path under its name.
        XCTAssertTrue(app.staticTexts["~/code/site"].waitForExistence(timeout: 10) || text(app, "~/code/site").exists,
                      "no folder path")
        let one = row(app, "recent-7c1e9a52-3f0b-4d8e-9a61-0b5c2e7d4f10")
        XCTAssertTrue(one.waitForExistence(timeout: 10), "the conversation isn't listed")
        one.tap()
        // Asked in its row, not a dialog.
        XCTAssertTrue(text(app, "接管「首页改成两栏布局」？").waitForExistence(timeout: 5), "not asked")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        app.buttons["接管"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["首页改成两栏布局"].waitForExistence(timeout: 15), "its Pal's page didn't open")
        XCTAssertTrue(text(app, "两栏改好了").waitForExistence(timeout: 10), "its conversation so far isn't there")
        back(app)
        XCTAssertTrue(app.staticTexts["Pals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "首页改成两栏布局")).firstMatch.exists,
                      "it isn't a Pal on the list")
    }

    /// When the computer can't, the row says why in plain words, and 好 puts it back.
    @MainActor
    func testARecentConversationThatCantBeAdoptedSaysWhy() throws {
        let app = launch(["-demoScreen", "recent", "-demoAdoptError", "已经开着 5 个 Pal 了，最久没用的是「笔记整理」"])
        let one = row(app, "recent-e4a7c3d9-1b6f-4e2a-b8c5-9d0e7f3a2c61")
        XCTAssertTrue(one.waitForExistence(timeout: 15))
        one.tap()
        app.buttons["接管"].firstMatch.tap()
        XCTAssertTrue(text(app, "没接管成：已经开着 5 个 Pal 了").waitForExistence(timeout: 10), "no reason given")
        attach(app, "recent-failed")
        app.buttons["好"].firstMatch.tap()
        XCTAssertTrue(one.waitForExistence(timeout: 5), "the row didn't come back")
        XCTAssertTrue(app.navigationBars.staticTexts["最近的对话"].exists, "left the page")
    }

    // MARK: -

    @MainActor
    private func text(_ app: XCUIApplication, _ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch
    }

    /// Scrolls the list up until the element is there (a list only makes
    /// the rows on screen).
    @MainActor
    private func scrolledTo(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        for _ in 0..<4 where !element.exists { app.swipeUp() }
        return element.exists
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// The system back button, top left.
    @MainActor
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-demo", "YES"] + args
        app.launch()
        return app
    }
}
