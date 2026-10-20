#if targetEnvironment(macCatalyst)
import XCTest

/// The basics on the Mac, walked before any build reaches the owner: Palo, a
/// session, a workspace and one of its sessions open from the sidebar; the
/// composer takes typing; the ＋ menu and 设置 open; the right pane opens. In
/// dark and in light. Each step attaches a picture of the app's window.
///
/// Run like MacScrollWheelUITests (see its header), with
/// `-only-testing:PaloAllyUITests/MacSmokeUITests`; the screen must be unlocked.
final class MacSmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testBasicsDark() throws { try walk("dark") }
    @MainActor func testBasicsLight() throws { try walk("light") }

    @MainActor
    private func walk(_ look: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                "-demoWindow", "1300x850", "-demoAppearance", look]
        app.launch()
        defer { app.terminate() }

        let palo = app.descendants(matching: .any)["row-palo"].firstMatch
        XCTAssertTrue(palo.waitForExistence(timeout: 30), "no Palo in the sidebar")
        sleep(2)
        shot(app, "\(look)-1-palo")

        // A session.
        let notes = app.descendants(matching: .any)["row-pal-pal-notes"].firstMatch
        XCTAssertTrue(notes.exists, "no 笔记整理 in the sidebar")
        notes.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-capsule"].waitForExistence(timeout: 5), "the session didn't open")
        type(app, "你好")
        shot(app, "\(look)-2-session")

        // Back to Palo.
        palo.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-orb"].waitForExistence(timeout: 5), "Palo didn't open")
        type(app, "测试")
        shot(app, "\(look)-3-palo-typed")

        // A workspace, then one of its sessions.
        let ws = app.descendants(matching: .any)["row-workspace-ws-site"].firstMatch
        XCTAssertTrue(ws.exists, "no 官网改版 workspace in the sidebar")
        ws.click()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-page"].waitForExistence(timeout: 5), "the workspace didn't open")
        sleep(1)
        shot(app, "\(look)-4-workspace")
        let member = app.descendants(matching: .any)["row-pal-pal-site"].firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 5), "the workspace's 网站帮手 isn't listed")
        member.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-capsule"].waitForExistence(timeout: 5), "the member didn't open")
        shot(app, "\(look)-5-member")

        // The right pane.
        let pane = app.buttons["右侧栏"].firstMatch
        XCTAssertTrue(pane.exists, "no right-pane button")
        pane.click()
        sleep(1)
        shot(app, "\(look)-6-pane")
        pane.click()

        // ＋ opens its menu.
        let add = app.descendants(matching: .any)["sidebar-add"].firstMatch
        XCTAssertTrue(add.exists, "no ＋ in the sidebar's foot")
        add.click()
        XCTAssertTrue(app.menuItems["新建会话"].waitForExistence(timeout: 5), "＋ didn't open its menu")
        shot(app, "\(look)-7-add-menu")
        app.typeKey(.escape, modifierFlags: [])

        // 设置 opens.
        let settings = app.descendants(matching: .any)["sidebar-settings"].firstMatch
        XCTAssertTrue(settings.exists, "no 设置 in the sidebar's foot")
        settings.click()
        sleep(1)
        shot(app, "\(look)-8-settings")
    }

    /// Clicks the page's composer and types; the text must land in it.
    @MainActor
    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no composer")
        field.click()
        field.typeText(text)
        let typed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'composerField' AND value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 3), "typing didn't reach the composer")
        // Leave it empty for the next page.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
#endif
