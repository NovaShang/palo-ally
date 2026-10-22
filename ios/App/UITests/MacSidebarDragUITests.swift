#if targetEnvironment(macCatalyst)
import XCTest

/// The sidebar's drag and drop on the Mac, with real pointer drags, and the
/// rows still opening on a click before and after (a drag of our own on the
/// rows once took the clicks). The demo: 官网改版 holds 网站帮手 and 博客改版;
/// 笔记整理 is the one ordinary session shown.
///
/// Run like MacSmokeUITests, with
/// `-only-testing:PaloAllyUITests/MacSidebarDragUITests`; the screen must be unlocked.
final class MacSidebarDragUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDragsReorderMoveAndGroupAndClicksStillOpen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                "-demoWindow", "1300x850"]
        app.launch()
        defer { app.terminate() }

        func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        let palo = row("row-palo")
        XCTAssertTrue(palo.waitForExistence(timeout: 30), "no Palo in the sidebar")
        sleep(2)
        let notes = row("row-pal-pal-notes"), site = row("row-pal-pal-site"), blog = row("row-pal-pal-blog")
        let ws = row("row-workspace-ws-site"), sessionsHeader = app.staticTexts["会话"].firstMatch
        XCTAssertTrue(notes.exists && ws.exists && sessionsHeader.exists, "the demo's rows aren't there")

        // A click opens a session, and Palo again.
        notes.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-capsule"].waitForExistence(timeout: 5), "a click didn't open the session")
        palo.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-orb"].waitForExistence(timeout: 5), "a click didn't open Palo")
        shot(app, "1-before")

        // Into the workspace: dropped onto its row (which opens to show it).
        drag(notes, to: ws, dy: 0.5)
        XCTAssertTrue(site.waitForExistence(timeout: 5) && blog.exists, "the workspace didn't open to its sessions")
        sleep(2)
        shot(app, "2-into-workspace")
        XCTAssertLessThan(notes.frame.minY, sessionsHeader.frame.minY, "笔记整理 didn't move into 官网改版")

        // Reorder inside it: 笔记整理 above 网站帮手.
        drag(notes, to: site, dy: 0.1)
        sleep(2)
        shot(app, "3-members-reordered")
        XCTAssertLessThan(notes.frame.minY, site.frame.minY, "dragging a member above another didn't reorder them")

        // Out of it: 博客改版 onto 会话.
        XCTAssertLessThan(blog.frame.minY, sessionsHeader.frame.minY)
        drag(blog, to: sessionsHeader, dy: 0.5)
        sleep(2)
        shot(app, "4-out-of-workspace")
        XCTAssertGreaterThan(blog.frame.minY, sessionsHeader.frame.minY, "博客改版 didn't move out to 会话")

        // Clicks still open rows after the drags.
        blog.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-capsule"].waitForExistence(timeout: 5), "a click after the drags didn't open the session")
        ws.click()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-page"].waitForExistence(timeout: 5), "a click didn't open the workspace")
        palo.click()
        XCTAssertTrue(app.descendants(matching: .any)["title-orb"].waitForExistence(timeout: 5), "a click didn't open Palo")

        // One session onto another ordinary one: 新建工作区 for the two.
        drag(site, to: blog, dy: 0.5)
        sleep(2)
        shot(app, "5-group-sheet")
        XCTAssertTrue(app.staticTexts["新建工作区"].firstMatch.waitForExistence(timeout: 5)
                      || app.navigationBars["新建工作区"].firstMatch.exists,
                      "dropping a session onto another didn't ask for a new workspace")
    }

    /// A real pointer drag from `a`'s middle to a point `dy` down `b`.
    @MainActor
    private func drag(_ a: XCUIElement, to b: XCUIElement, dy: CGFloat) {
        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
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
