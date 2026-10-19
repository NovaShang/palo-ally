import XCTest

/// Pictures that a page names by relative path, against the demo host on an
/// iPhone simulator: a 成果 HTML page and a 成果 Markdown page show the images
/// published beside them, and a Markdown file in a Pal's folder shows the
/// image next to it. An image that isn't there is a quiet stub, not a blank.
final class ImagesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAnHTMLLibraryPageShowsItsPublishedImage() throws {
        let app = launch(["-demoScreen", "artifact", "-demoArtifact", "ar2"])
        let hotel = picture(app, "酒店外观")
        XCTAssertTrue(hotel.waitForExistence(timeout: 20), "the page's image never showed")
        assertDrawn(hotel)
        // The one that isn't in the item is a stub; the page is still there.
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "丢了的图")).firstMatch
            .waitForExistence(timeout: 10), "no stub for the missing image")
        XCTAssertTrue(app.webViews.staticTexts["上海出行比价"].exists)
        shot(app, "html-library-image")
    }

    @MainActor
    func testAMarkdownLibraryPageShowsItsPublishedImage() throws {
        let app = launch(["-demoScreen", "artifact", "-demoArtifact", "ar1"])
        let weather = picture(app, "天气图")
        XCTAssertTrue(weather.waitForExistence(timeout: 20), "the page's image never showed")
        assertDrawn(weather)
        shot(app, "markdown-library-image")
    }

    @MainActor
    func testAMarkdownFileOnTheComputerShowsItsImage() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 15))
        app.buttons["title-capsule"].firstMatch.tap()
        app.buttons["detail-files"].firstMatch.tap()
        let readme = app.buttons["file-row-README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 10), "no README.md in the tree")
        readme.tap()
        let image = picture(app, "首页示意")
        XCTAssertTrue(image.waitForExistence(timeout: 20), "the file's image never showed")
        assertDrawn(image)
        shot(app, "file-tree-markdown-image")
    }

    @MainActor
    func testAMissingImageInAComputerFileIsAStub() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site", "-demoFilePath", "notes/设计/列表页.md"])
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 15))
        app.buttons["title-capsule"].firstMatch.tap()
        app.buttons["detail-files"].firstMatch.tap()
        let sketch = picture(app, "草图")
        XCTAssertTrue(sketch.waitForExistence(timeout: 20), "the note's sketch never showed")
        assertDrawn(sketch)
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "缺图")).firstMatch
            .waitForExistence(timeout: 10), "no stub for the missing image")
        shot(app, "file-tree-markdown-stub")
    }

    // MARK: helpers

    /// The page's `<img>` by its alt text, however the web view exposes it (an SVG shows up as an Other).
    @MainActor
    private func picture(_ app: XCUIApplication, _ alt: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND elementType != %d", alt, XCUIElement.ElementType.staticText.rawValue)).firstMatch
    }

    @MainActor
    private func assertDrawn(_ image: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(image.frame.width, 40, "the image has no width", file: file, line: line)
        XCTAssertGreaterThan(image.frame.height, 20, "the image has no height", file: file, line: line)
    }

    /// Simulator only (the app's own screenshot), kept as an attachment and as
    /// a file for the review.
    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = URL(fileURLWithPath: "/tmp/paloally-images/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"] + args
        app.launch()
        return app
    }
}
