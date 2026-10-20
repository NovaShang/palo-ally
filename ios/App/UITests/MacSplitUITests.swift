#if targetEnvironment(macCatalyst)
import XCTest

/// A split workspace on the Mac (docs/workbench-design/split-final.html),
/// walked with real clicks, drags and keys: typing goes to the pane clicked,
/// the status icon opens the pane's details, ⋯ opens its menu, a divider
/// moves on release, a pane dragged by its header swaps with another or
/// splits it, ⌘⌥→ moves the caret to the next pane. In dark and in light;
/// each step attaches a picture of the window.
///
/// Run like MacScrollWheelUITests (see its header), with
/// `-only-testing:PaloAllyUITests/MacSplitUITests`; the screen must be unlocked.
final class MacSplitUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testSplitLight() throws { try walk("light") }
    @MainActor func testSplitDark() throws { try walk("dark") }

    @MainActor
    private func walk(_ look: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                "-demoScreen", "workspace", "-demoTiles", "3",
                                "-demoWindow", "1300x850", "-demoAppearance", look]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["workspace-page"].waitForExistence(timeout: 30), "no workspace page")
        let site = header(app, "pal-site"), blog = header(app, "pal-blog"), notes = header(app, "pal-notes")
        XCTAssertTrue(site.waitForExistence(timeout: 10), "no status icon on 网站帮手's pane")
        XCTAssertTrue(blog.exists && notes.exists, "not three panes")
        sleep(2)
        shot(app, "\(look)-1-split")

        // Typing goes to the pane clicked.
        let blogField = field(app, in: blog)
        blogField.click()
        blogField.typeText("你好")
        XCTAssertTrue((blogField.value as? String ?? "").contains("你好"), "typing didn't reach 博客改版's composer")
        let siteField = field(app, in: site)
        siteField.click()
        siteField.typeText("在吗")
        XCTAssertTrue((siteField.value as? String ?? "").contains("在吗"), "typing didn't reach 网站帮手's composer")
        XCTAssertFalse((blogField.value as? String ?? "").contains("在吗"), "typing reached the other pane too")
        shot(app, "\(look)-2-typed")

        // ⌘⌥→: the caret goes to the next pane.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        sleep(1)
        app.typeText("右")
        XCTAssertTrue((blogField.value as? String ?? "").contains("右"), "⌘⌥→ didn't move the caret to the next pane")
        shot(app, "\(look)-3-next-pane")

        // The status icon opens the details.
        site.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent-detail"].waitForExistence(timeout: 5), "the details didn't open")
        sleep(1)
        shot(app, "\(look)-4-details")
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        // ⋯ opens the pane's menu.
        let menu = app.descendants(matching: .any)["tile-menu-pal-blog"].firstMatch
        XCTAssertTrue(menu.exists, "no ⋯ on 博客改版's pane")
        menu.click()
        XCTAssertTrue(app.menuItems["单独打开"].waitForExistence(timeout: 5), "⋯ didn't open its menu")
        for item in ["右栏（成果 / 文件）", "重命名…", "移出工作区", "关闭这格", "结束会话…"] {
            XCTAssertTrue(app.menuItems[item].exists, "no \(item) in the menu")
        }
        shot(app, "\(look)-5-menu")
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        // A divider: hovered, then dragged 150 pt right; the pane beside it follows on release.
        let blogX = blog.frame.minX
        let gap = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: blogX - 8.5 - app.windows.firstMatch.frame.minX,
                                 dy: blog.frame.midY + 120 - app.windows.firstMatch.frame.minY))
        gap.hover()
        sleep(1)
        shot(app, "\(look)-6-divider-hover")
        gap.press(forDuration: 0.3, thenDragTo: gap.withOffset(CGVector(dx: 150, dy: 0)))
        sleep(1)
        XCTAssertEqual(blog.frame.minX, blogX + 150, accuracy: 6, "the divider didn't move 博客改版's pane")
        shot(app, "\(look)-7-divider-moved")

        // 笔记整理 dragged by its header onto the middle of 网站帮手: they swap.
        let notesTitle = title(app, "pal-notes")
        let siteFrame = paneFrame(app, site)
        let from = notesTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: siteFrame.midX - app.windows.firstMatch.frame.minX,
                                 dy: siteFrame.midY - app.windows.firstMatch.frame.minY))
        from.press(forDuration: 0.3, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(1)
        XCTAssertLessThan(notes.frame.minY, site.frame.minY, "dropping on the middle didn't swap the panes")
        shot(app, "\(look)-8-swapped")

        // 网站帮手 (now below) dragged onto the right edge of 博客改版: it splits it.
        let blogFrame = paneFrame(app, blog)
        let siteTitle = title(app, "pal-site")
        let edge = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: blogFrame.maxX - blogFrame.width * 0.1 - app.windows.firstMatch.frame.minX,
                                 dy: blogFrame.midY - app.windows.firstMatch.frame.minY))
        siteTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(1)
        XCTAssertEqual(site.frame.minY, blog.frame.minY, accuracy: 4, "dropping on the edge didn't put 网站帮手 beside 博客改版")
        XCTAssertGreaterThan(site.frame.minX, blog.frame.minX, "网站帮手 isn't on 博客改版's right")
        shot(app, "\(look)-9-split-edge")
    }

    private func header(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["tile-header-\(id)"].firstMatch
    }

    private func title(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["tile-title-\(id)"].firstMatch
    }

    /// The composer of the pane whose status icon is `icon`: the one below it, in its column.
    private func field(_ app: XCUIApplication, in icon: XCUIElement) -> XCUIElement {
        let fields = app.descendants(matching: .any).matching(identifier: "composerField").allElementsBoundByIndex
        let x = icon.frame.minX, y = icon.frame.minY
        return fields.filter { $0.frame.minY > y && $0.frame.minX > x - 20 && $0.frame.minX < x + 400 }
            .min { $0.frame.minY < $1.frame.minY } ?? fields[0]
    }

    /// A pane's rect: from its status icon to its composer's bottom, across to its ⋯.
    private func paneFrame(_ app: XCUIApplication, _ icon: XCUIElement) -> CGRect {
        let f = field(app, in: icon).frame
        let top = icon.frame.minY - 5
        let left = icon.frame.minX - 8
        let right = max(f.maxX + 12, left + 200)
        return CGRect(x: left, y: top, width: right - left, height: f.maxY + 6 - top)
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
