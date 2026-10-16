import XCTest

/// Files on the computer (docs/files-prd.md) against the demo host on an
/// iPhone simulator, with real taps: a Pal's ⋯ → 文件 opens its folder's
/// tree, a Markdown file renders and back returns to the tree; a long press
/// inserts a file's path into that Pal's composer; a path in a Pal's reply
/// is a link that opens the file; 成果 → 打开文件夹… shows the folder's tree;
/// the composer's 电脑上的文件 puts a `[文件] <path>` line in the message.
final class FilesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAPalsFilesOpenAMarkdownFileAndGoBack() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        openPalFiles(app)
        let readme = app.buttons["file-row-README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 10), "no README.md in the tree")
        XCTAssertFalse(app.buttons["file-row-node_modules"].exists, "node_modules shows before it's asked for")
        attach(app, "pal-files-tree")
        readme.tap()
        XCTAssertTrue(app.descendants(matching: .any)["file-page"].waitForExistence(timeout: 10), "the Markdown file didn't open")
        XCTAssertTrue(app.webViews.staticTexts["网站"].waitForExistence(timeout: 10), "the Markdown isn't rendered")
        attach(app, "pal-files-markdown")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(readme.waitForExistence(timeout: 5), "back didn't return to the tree")
        // A folder opens in place; search finds a file deep down.
        app.buttons["file-row-src"].firstMatch.tap()
        XCTAssertTrue(app.buttons["file-row-src/app.ts"].waitForExistence(timeout: 5), "src didn't open")
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("useItems")
        XCTAssertTrue(text(app, "src/hooks").waitForExistence(timeout: 5), "search found nothing")
        attach(app, "pal-files-search")
    }

    @MainActor
    func testALongPressInsertsTheRelativePathIntoThePalsComposer() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        openPalFiles(app)
        let src = app.buttons["file-row-src"].firstMatch
        XCTAssertTrue(src.waitForExistence(timeout: 10), "no src in the tree")
        src.tap()
        let file = app.buttons["file-row-src/app.ts"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), "src didn't open")
        file.press(forDuration: 1.0)
        let insert = app.buttons["插入到输入框"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "no 插入到输入框 on a long press")
        attach(app, "pal-files-long-press")
        insert.tap()
        let field = app.descendants(matching: .any)["composerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let typed = NSPredicate(format: "value CONTAINS %@", "src/app.ts")
        expectation(for: typed, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        attach(app, "pal-files-inserted")
    }

    @MainActor
    func testAPathInAPalsReplyOpensTheFile() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 15), "the Pal's page didn't open")
        let link = app.links["ListPage.tsx"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "ListPage.tsx in the reply isn't a link")
        // Out from under the bar.
        app.swipeDown()
        // Not a file on the computer: stays plain text.
        XCTAssertFalse(app.links["updatedAt"].exists)
        attach(app, "reply-path-link")
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["file-page"].waitForExistence(timeout: 10), "the file didn't open")
        let code = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "useItems")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the code isn't shown")
        attach(app, "reply-path-preview")
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5), "closing didn't return to the conversation")
    }

    @MainActor
    func testOpenFolderShowsItsTreeAndRemembersIt() throws {
        let app = launch(["-demoScreen", "library"])
        let open = app.buttons["open-folder"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10), "no 打开文件夹… in 成果")
        open.tap()
        let code = app.buttons["folder-row-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the picker doesn't start at the home folder")
        attach(app, "folder-picker-home")
        code.tap()
        app.buttons["folder-row-blog"].tap()
        let confirm = app.buttons["open-this-folder"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.label.contains("blog"), "the button doesn't name the folder: \(confirm.label)")
        attach(app, "folder-picker-blog")
        confirm.tap()
        XCTAssertTrue(app.buttons["file-row-README.md"].waitForExistence(timeout: 10), "the folder's tree didn't show")
        attach(app, "folder-tree")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["owner-folder-blog"].waitForExistence(timeout: 5), "the folder isn't remembered in 成果")
    }

    @MainActor
    func testComputerFileInTheComposerPutsItsPathInTheMessage() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        let plus = app.buttons["添加照片或文件"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "no [+] on the composer")
        plus.tap()
        let item = app.buttons["电脑上的文件"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no 电脑上的文件 in [+]")
        item.tap()
        let readme = app.buttons["pick-row-README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 10), "the picker doesn't start in the Pal's folder")
        attach(app, "computer-file-picker")
        readme.tap()
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "[文件] /Users/demo/code/site/README.md"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        attach(app, "computer-file-inserted")
    }

    // MARK: helpers

    @MainActor
    private func openPalFiles(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 15), "the Pal's page didn't open")
        let menu = app.buttons["pal-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no ⋯ on the Pal's page")
        menu.tap()
        let files = app.buttons["文件"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), "no 文件 in ⋯")
        files.tap()
        XCTAssertTrue(app.descendants(matching: .any)["file-tree"].firstMatch.waitForExistence(timeout: 10), "the tree didn't open")
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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"] + args
        app.launch()
        return app
    }
}
