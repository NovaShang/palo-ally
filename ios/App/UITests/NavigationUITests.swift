import XCTest

/// Standard navigation (pals-prd §2, §3, §5) against the demo host on an
/// iPhone simulator: the app opens in the assistant's conversation, back is
/// the list, an agent and a 好友 open from it, the orb opens the assistant's
/// details, 右侧栏 opens the pane (成果 among its tabs), typing to one of the
/// host's other Claude Code sessions takes it over (a terminal's once it is
/// quit there), and 已归档 brings back one that ended.
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchLandsInTheAssistantsConversation() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 15), "no orb: not the assistant's conversation")
        XCTAssertTrue(app.buttons["按住说话，轻点打字"].exists, "no composer")
        XCTAssertTrue(app.buttons["page-files"].exists, "no 右侧栏 in the toolbar")
        // The list is one step back, not on screen.
        XCTAssertFalse(app.staticTexts["Agent"].exists)
    }

    @MainActor
    func testBackGoesToTheList() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 15))
        back(app)
        XCTAssertTrue(app.staticTexts["Agent"].waitForExistence(timeout: 5), "no agent section")
        XCTAssertTrue(row(app, "row-palo").exists, "no row for the assistant")
        XCTAssertTrue(row(app, "row-pal-pal-notes").exists, "no 笔记整理 under agent")
        // The host's other Claude Code sessions are agents like the rest; 已归档 N ends the section.
        XCTAssertTrue(scrolledTo(app, row(app, "row-session-cc-login")), "no terminal session under agent")
        XCTAssertTrue(scrolledTo(app, row(app, "row-archive")), "no 已归档 under agent")
        // The list runs past the screen: 好友 is further down.
        XCTAssertTrue(scrolledTo(app, row(app, "row-ally-al-family")), "no 好友 row")
        XCTAssertTrue(app.staticTexts["好友"].exists, "no 好友 section")
        // And in again.
        app.swipeDown()
        row(app, "row-palo").tap()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAPalOpensFromTheList() throws {
        let app = launch(["-demoScreen", "list"])
        // 网站帮手 is in the 官网改版 workspace: its arrow unfolds it in the list.
        let workspace = row(app, "row-workspace-ws-site")
        XCTAssertTrue(workspace.waitForExistence(timeout: 15), "no workspace in the list")
        workspace.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)).tap()
        let pal = row(app, "row-pal-pal-site")
        XCTAssertTrue(pal.waitForExistence(timeout: 5), "the workspace didn't unfold to its agents")
        pal.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 5), "the agent's page didn't open")
        XCTAssertTrue(app.buttons["title-capsule"].exists)
        XCTAssertFalse(app.buttons["title-orb"].exists, "an agent's page has no orb")
        XCTAssertTrue(app.buttons["允许"].firstMatch.waitForExistence(timeout: 5), "its card isn't there")
        back(app)
        XCTAssertTrue(app.staticTexts["Agent"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAContactOpensFromTheList() throws {
        let app = launch(["-demoScreen", "list"])
        XCTAssertTrue(app.staticTexts["Agent"].waitForExistence(timeout: 15))
        // Below the agents: the list scrolls to it.
        let ally = row(app, "row-ally-al-family")
        XCTAssertTrue(scrolledTo(app, ally), "no 好友 row")
        ally.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["家人"].waitForExistence(timeout: 5), "the 好友's page didn't open")
        XCTAssertTrue(app.descendants(matching: .any)["ally-input"].exists)
        XCTAssertTrue(app.staticTexts["路上小心"].exists || app.staticTexts["收到，路上小心。"].exists, "the exchanges aren't there")
    }

    /// The orb: the assistant's details as a sheet of tiles, 设置 a page of it; a tap above it is back in the conversation.
    @MainActor
    func testTheOrbOpensTheAssistantsDetails() throws {
        let app = launch()
        let orb = app.buttons["title-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15))
        orb.tap()
        let detail = app.descendants(matching: .any)["agent-detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the details didn't open")
        let settings = app.buttons["detail-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3) && settings.isHittable, "no 设置 among the tiles")
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "设置 didn't open")
        app.navigationBars["设置"].buttons.firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "not back on the tiles")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 5), "not back in the conversation")
    }

    @MainActor
    func testThePaneIsTheConversationsToolbarButton() throws {
        let app = launch()
        let pane = app.buttons["page-files"]
        XCTAssertTrue(pane.waitForExistence(timeout: 15))
        pane.tap()
        // The right pane as a full page: 等你 · 成果 · 待办 · 文件.
        XCTAssertTrue(app.descendants(matching: .any)["right-pane"].firstMatch.waitForExistence(timeout: 5), "the pane didn't open")
        XCTAssertTrue(text(app, "成果").exists, "no 成果 tab in the pane")
        app.buttons["关闭侧栏"].firstMatch.tap()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 5))
    }

    /// A Markdown item in 成果 opens rendered (a full-screen page over the
    /// phone's pane page), and closing it is the list again.
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
        XCTAssertTrue(app.descendants(matching: .any)["right-pane"].firstMatch.waitForExistence(timeout: 5), "closing didn't return to the pane")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "closing didn't return to 成果")
    }

    /// One still open in a terminal: before anything is typed its page says
    /// what typing does; what's typed waits (终端那边退出后发出) until it is
    /// quit there, then it is taken over and answers.
    @MainActor
    func testTypingToATerminalSessionWaitsUntilItIsQuitThenItAnswers() throws {
        let app = launch(["-demoScreen", "session", "-demoSession", "cc-login", "-demoAdoptAfter", "4", "-demoKeyboard", "4:600"])
        XCTAssertTrue(app.navigationBars.staticTexts["修登录跳转"].waitForExistence(timeout: 15), "its page didn't open")
        XCTAssertTrue(text(app, "登录以后会跳回首页").waitForExistence(timeout: 10), "its conversation so far isn't there")
        XCTAssertTrue(row(app, "agent-in-terminal").exists, "no word on the terminal it's open in")
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.typeText("登录后回到原来那一页")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(row(app, "agent-held").waitForExistence(timeout: 5), "no 终端那边退出后发出 while it waits")
        attach(app, "terminal-waiting")
        XCTAssertTrue(text(app, "好的，按你说的办").waitForExistence(timeout: 20), "it never answered once quit")
        XCTAssertFalse(row(app, "agent-held").exists, "still waiting after it was taken over")
    }

    /// 取消这条 calls the waiting words off; the page is as it was.
    @MainActor
    func testCancellingAWaitingMessageCallsItOff() throws {
        let app = launch(["-demoScreen", "session", "-demoSession", "cc-login", "-demoAdoptAfter", "0", "-demoKeyboard", "4:600"])
        XCTAssertTrue(app.navigationBars.staticTexts["修登录跳转"].waitForExistence(timeout: 15), "its page didn't open")
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.typeText("先别动登录页")
        app.buttons["发送"].firstMatch.tap()
        let cancel = row(app, "agent-held-cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no 取消这条")
        cancel.tap()
        XCTAssertTrue(row(app, "agent-in-terminal").waitForExistence(timeout: 5), "the page isn't as it was")
        XCTAssertFalse(row(app, "agent-held").exists, "the words still wait")
    }

    /// A background one: typing stops it and takes it over; its question came with it.
    @MainActor
    func testTypingToABackgroundSessionTakesItOver() throws {
        let app = launch(["-demoScreen", "session", "-demoSession", "cc-data", "-demoKeyboard", "4:600"])
        XCTAssertTrue(app.navigationBars.staticTexts["问卷数据清洗"].waitForExistence(timeout: 15), "its page didn't open")
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "B 用中位数补上")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "its question isn't on its page")
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.typeText("先跑完再说")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertTrue(text(app, "好的，按你说的办").waitForExistence(timeout: 15), "it never answered")
    }

    /// 已归档 (the list's last agent row): a conversation that ended, 拿回来
    /// in its row, then its page with its conversation so far.
    @MainActor
    func testBringingBackAConversationFromTheArchiveOpensItsPage() throws {
        let app = launch(["-demoScreen", "earlier"])
        XCTAssertTrue(row(app, "archive-page").waitForExistence(timeout: 15), "已归档 didn't open")
        let back = row(app, "archive-back-7c1e9a52-3f0b-4d8e-9a61-0b5c2e7d4f10")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the conversation isn't listed")
        back.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["首页改成两栏布局"].waitForExistence(timeout: 10), "its page didn't open")
        XCTAssertTrue(app.buttons["title-capsule"].exists, "not an agent's page")
        XCTAssertTrue(text(app, "两栏改好了").waitForExistence(timeout: 10), "its conversation so far isn't there")
    }

    /// When the host can't, the row says why in plain words and stays.
    @MainActor
    func testAConversationThatCantBeBroughtBackSaysWhy() throws {
        let app = launch(["-demoScreen", "earlier", "-demoAdoptError", "已经开着 5 个 agent 了，先归档一个"])
        let back = row(app, "archive-back-e4a7c3d9-1b6f-4e2a-b8c5-9d0e7f3a2c61")
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(text(app, "没能拿回来：已经开着 5 个 agent 了").waitForExistence(timeout: 10), "no reason given")
        attach(app, "archive-failed")
        XCTAssertTrue(back.waitForExistence(timeout: 5), "拿回来 didn't come back")
        XCTAssertFalse(app.buttons["title-capsule"].exists, "it was brought back after all")
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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"] + args
        app.launch()
        return app
    }
}
