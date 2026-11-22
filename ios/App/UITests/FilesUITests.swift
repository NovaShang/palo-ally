import XCTest

/// Files on the computer (docs/files-prd.md) against the demo host on an
/// iPhone simulator, with real taps: an agent's 右侧栏 → 文件 opens its folder's
/// tree, a Markdown file renders and back returns to the tree; a long press
/// inserts a file's path into that Pal's composer; a path in a Pal's reply
/// is a link that opens the file; the assistant's 文件 is the home folder;
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
        // The pane page's round search button turns its bar into the field.
        app.buttons["pane-search"].firstMatch.tap()
        let search = app.descendants(matching: .any)["pane-search-field"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no search field")
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

    /// The assistant's 文件 (成果 no longer lists opened folders, 6ef9058):
    /// the owner's home folder, a folder opening in place and a Markdown file
    /// from it; its capsule switches to the assistant's own files.
    @MainActor
    func testTheAssistantsFilesAreTheHomeFolder() throws {
        let app = launch([])
        let pane = app.buttons["page-files"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 15), "no 右侧栏 in the assistant's conversation")
        pane.tap()
        let files = app.buttons["pane-tab-files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), "no 文件 tab in the pane")
        files.tap()
        let code = app.buttons["file-row-code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "文件 doesn't start at the home folder")
        attach(app, "home-folder")
        code.tap()
        let blog = app.buttons["file-row-code/blog"].firstMatch
        XCTAssertTrue(blog.waitForExistence(timeout: 5), "code didn't open")
        blog.tap()
        let readme = app.buttons["file-row-code/blog/README.md"].firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 5), "blog didn't open")
        attach(app, "home-folder-blog")
        // The capsule: the assistant's own files instead.
        let root = app.descendants(matching: .any)["files-root"].firstMatch
        XCTAssertTrue(root.exists, "no folder capsule")
        root.tap()
        app.buttons["助理的文件"].firstMatch.tap()
        XCTAssertTrue(code.waitForNonExistence(timeout: 5), "still the home folder")
        attach(app, "assistant-files")
    }

    @MainActor
    func testComputerFileInTheComposerPutsItsPathInTheMessage() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        let plus = app.buttons["添加照片或文件"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "no [+] on the composer")
        plus.tap()
        let item = app.buttons["主机上的文件"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no 主机上的文件 in [+]")
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
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 15), "the agent's page didn't open")
        // 右侧栏, then its 文件 tab.
        let pane = app.buttons["page-files"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5), "no 右侧栏 on the agent's page")
        pane.tap()
        let files = app.buttons["pane-tab-files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), "no 文件 tab in the pane")
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
