import XCTest

/// 成果 sorted by time or by folder (docs/files-prd.md), against the demo host
/// on an iPhone simulator, in light and dark: the timeline is the default,
/// the segmented control switches to folders, a folder folds shut, and
/// search finds an item in either view.
final class LibraryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheTimelineIsTheDefaultAndFoldersFold() throws {
        for style in ["Light", "Dark"] {
            let app = launch(style: style)
            let picker = app.segmentedControls["library-grouping"]
            XCTAssertTrue(picker.waitForExistence(timeout: 20), "no 按时间 / 按文件夹 in 成果 (\(style))")
            XCTAssertTrue(picker.buttons["按时间"].isSelected, "按时间 isn't the default")
            XCTAssertTrue(app.staticTexts["今天"].waitForExistence(timeout: 5), "no 今天 section")
            XCTAssertTrue(app.staticTexts["上海行程"].exists)
            attach(app, "library-time-\(style)")

            picker.buttons["按文件夹"].tap()
            let travel = app.buttons["library-folder-旅行"]
            XCTAssertTrue(travel.waitForExistence(timeout: 5), "no 旅行 folder")
            XCTAssertTrue(app.staticTexts["上海出行比价"].exists)
            attach(app, "library-folders-\(style)")

            travel.tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["上海出行比价"])
            waitForExpectations(timeout: 5)
            attach(app, "library-folded-\(style)")
            travel.tap()
            XCTAssertTrue(app.staticTexts["上海出行比价"].waitForExistence(timeout: 5), "the folder didn't open again")
            // The artifacts without a folder come last, in 其他.
            app.swipeUp()
            app.swipeUp()
            XCTAssertTrue(app.buttons["library-folder-none"].waitForExistence(timeout: 5), "no group for items without a folder")
            XCTAssertTrue(app.staticTexts["暑假阅读清单"].exists)
            attach(app, "library-folders-end-\(style)")
            app.swipeDown()
            app.swipeDown()
            // Leave the kept choice as it was found.
            picker.buttons["按时间"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testSearchFindsAnItemInEitherView() throws {
        for grouping in ["time", "folder"] {
            let app = launch(style: "Light", grouping: grouping, query: "账单")
            XCTAssertTrue(app.staticTexts["水电燃气账单"].waitForExistence(timeout: 20), "search found nothing in \(grouping)")
            XCTAssertFalse(app.staticTexts["上海行程"].exists)
            if grouping == "folder" { attach(app, "library-search") }
            app.terminate()
        }
    }

    // MARK: helpers

    @MainActor
    private func launch(style: String, grouping: String? = nil, query: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-AppleInterfaceStyle", style,
                                "-demo", "YES", "-demoScreen", "library"]
        // On the command line the choice can't be changed by a tap, so only the search test passes it.
        if let grouping { app.launchArguments += ["-libraryGrouping", grouping] }
        if let query { app.launchArguments += ["-libraryQuery", query] }
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
