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

    /// The mask behind holding to talk, alone, over a session's page: the
    /// page must show through it, frosted.
    @MainActor func testVoiceScrim() throws {
        for look in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                    "-demoAppearance", look, "-demoScrim", "YES"]
            app.launch()
            XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 20))
            sleep(2)
            shot(app, "\(look)-scrim")
            app.terminate()
        }
    }

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
        // 文件 in its glass tab bar, then the search that takes the bar's place.
        let filesTab = app.descendants(matching: .any)["pane-tab-files"].firstMatch
        if !filesTab.exists {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(look)-pane-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(filesTab.exists, "the pane has no 文件 tab")
        filesTab.tap()
        sleep(2)
        shot(app, "\(look)-4b-palo-files")
        // Its capsule switches between the owner's home folder and Palo's own.
        let root = app.descendants(matching: .any)["files-root"].firstMatch
        XCTAssertTrue(root.exists, "Palo's 文件 has no folder capsule")
        root.tap()
        let palos = app.buttons["Palo 的文件"].firstMatch
        XCTAssertTrue(palos.waitForExistence(timeout: 3), "the capsule's menu has no Palo 的文件")
        palos.tap()
        sleep(2)
        shot(app, "\(look)-4b2-palo-own-files")
        app.descendants(matching: .any)["pane-tab-library"].firstMatch.tap()
        let search = app.descendants(matching: .any)["pane-search"].firstMatch
        XCTAssertTrue(search.exists, "the pane has no search button")
        search.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pane-search-field"].firstMatch.waitForExistence(timeout: 3), "no search field")
        app.typeText("上海")
        sleep(1)
        shot(app, "\(look)-4c-palo-search")
        app.buttons["取消搜索"].firstMatch.tap()
        let close = app.buttons["关闭侧栏"].firstMatch
        XCTAssertTrue(close.exists, "the pane has no close button")
        close.tap()
        XCTAssertTrue(palo.waitForExistence(timeout: 5), "closing the pane didn't return to Palo")

        // The list, then a session.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let site = app.descendants(matching: .any)["row-pal-pal-notes"].firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5), "no 笔记整理 in the list")
        shot(app, "\(look)-5-list")
        // ＋ → 从历史记录继续…
        app.buttons["sidebar-add"].firstMatch.tap()
        let history = app.buttons["从历史记录继续…"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 3), "no 从历史记录继续… in the ＋ menu")
        shot(app, "\(look)-5b-add-menu")
        history.tap()
        XCTAssertTrue(app.descendants(matching: .any)["history-picker"].firstMatch.waitForExistence(timeout: 5), "the history list didn't open")
        sleep(2)
        shot(app, "\(look)-5c-history")
        app.buttons["完成"].firstMatch.tap()
        sleep(1)
        site.tap()
        let session = app.buttons["title-capsule"]
        XCTAssertTrue(session.waitForExistence(timeout: 5), "the session's page has no indicator")
        XCTAssertTrue(app.buttons["page-files"].exists, "the session's page has no right-pane button")
        sleep(1)
        shot(app, "\(look)-6-session")
        // Its pane: 成果, this session's.
        app.buttons["page-files"].tap()
        sleep(2)
        shot(app, "\(look)-6b-session-pane")
        app.buttons["关闭侧栏"].firstMatch.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 5), "closing the session's pane didn't return to it")
        session.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent-detail"].waitForExistence(timeout: 5), "the session's details didn't open")
        sleep(1)
        shot(app, "\(look)-7-session-details")
        // Pulled up to the full height: the rest of it.
        app.descendants(matching: .any)["agent-detail"].firstMatch.swipeUp()
        sleep(1)
        shot(app, "\(look)-7b-session-details-full")
        // Its depth can be chosen, by its full name.
        let effort = app.descendants(matching: .any)["detail-effort"].firstMatch
        XCTAssertTrue(effort.exists, "the session's details have no 思考深度")
        effort.tap()
        let deep = app.buttons["深"].firstMatch
        XCTAssertTrue(deep.waitForExistence(timeout: 3), "思考深度's menu didn't open with its full names")
        shot(app, "\(look)-7c-effort-menu")
        deep.tap()
        sleep(1)
        app.buttons["完成"].firstMatch.tap()
        // An ordinary session has no quick-switch strip.
        XCTAssertFalse(app.descendants(matching: .any)["quick-switch"].exists, "a session outside a workspace has the strip")

        // A session in a workspace: the strip of its sessions above the composer.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The phone opens a workspace as the list of its sessions.
        let wsRow = app.descendants(matching: .any)["row-workspace-ws-site"].firstMatch
        XCTAssertTrue(wsRow.waitForExistence(timeout: 5), "no workspace in the list")
        wsRow.tap()
        let siteRow = app.descendants(matching: .any)["workspace-member-pal-site"].firstMatch
        XCTAssertTrue(siteRow.waitForExistence(timeout: 5), "the workspace's page doesn't list its sessions")
        siteRow.tap()
        let strip = app.descendants(matching: .any)["quick-switch"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "a session in a workspace has no quick-switch strip")
        sleep(1)
        shot(app, "\(look)-8-quick-switch")
        // A tap on a chip goes to its session.
        app.descendants(matching: .any)["quick-switch-pal-blog"].firstMatch.tap()
        let blog = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'quick-switch-pal-blog' AND selected == true")).firstMatch
        XCTAssertTrue(blog.waitForExistence(timeout: 5), "tapping a chip didn't go to its session")
        sleep(1)
        shot(app, "\(look)-8b-quick-switch-swiped")
        // A tap goes back.
        app.descendants(matching: .any)["quick-switch-pal-site"].firstMatch.tap()
        let site2 = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'quick-switch-pal-site' AND selected == true")).firstMatch
        XCTAssertTrue(site2.waitForExistence(timeout: 5), "tapping a chip didn't switch")
        // Long press: its menu.
        app.descendants(matching: .any)["quick-switch-pal-blog"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["结束会话"].firstMatch.waitForExistence(timeout: 3), "long press on a chip has no menu")
        shot(app, "\(look)-8c-quick-switch-menu")
        app.descendants(matching: .any)["quick-switch"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -8)).tap()
        sleep(1)
        // Typing puts it away.
        type(app, "测试")
        XCTAssertFalse(app.descendants(matching: .any)["quick-switch"].exists, "the strip stays while typing")
        shot(app, "\(look)-8d-quick-switch-typing")
        dismissKeyboard(app)
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "the strip didn't come back after typing")

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
