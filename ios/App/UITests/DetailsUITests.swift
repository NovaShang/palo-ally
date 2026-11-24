import XCTest

/// The details' tiles on a phone (docs/workbench-design/details-v5.html)
/// against the demo host: an agent's depth, model, tasks, name, pages and
/// 归档 asked; the assistant's 目标 and 设置.
final class DetailsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A bar is the depth; the whole column takes the tap.
    @MainActor
    func testABarChangesTheDepth() throws {
        let app = openAgent()
        let max = app.buttons["detail-effort-max"].firstMatch
        XCTAssertTrue(max.waitForExistence(timeout: 5), "no 思考深度")
        XCTAssertTrue(app.buttons["detail-effort-high"].firstMatch.isSelected, "网站帮手 doesn't think at 深")
        // The shortest bar, at its column's top.
        app.buttons["detail-effort-low"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(selected(app.buttons["detail-effort-low"].firstMatch), "its column's top isn't the bar's")
        max.tap()
        XCTAssertTrue(selected(max), "最深 wasn't taken")
        XCTAssertTrue(app.staticTexts["最深"].firstMatch.exists, "the tile doesn't say 最深")
        attach(app, "depth")
    }

    /// Across the bars with a finger.
    @MainActor
    func testADragGoesAcrossTheBars() throws {
        let app = openAgent()
        let low = app.buttons["detail-effort-low"].firstMatch, max = app.buttons["detail-effort-max"].firstMatch
        XCTAssertTrue(low.waitForExistence(timeout: 5))
        low.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: max.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(selected(max), "the drag didn't end on 最深")
        XCTAssertTrue(app.descendants(matching: .any)["agent-detail"].firstMatch.exists, "the drag closed the sheet")
    }

    /// A model that takes fewer depths has fewer bars.
    @MainActor
    func testTheModelMenu() throws {
        let app = openAgent()
        let model = app.buttons["detail-model"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5), "no 模型")
        model.tap()
        let sonnet = app.buttons["Sonnet 4.5"].firstMatch
        XCTAssertTrue(sonnet.waitForExistence(timeout: 5), "the menu didn't open")
        attach(app, "model-menu")
        sonnet.tap()
        XCTAssertTrue(app.buttons["detail-effort-max"].firstMatch.waitForNonExistence(timeout: 5), "still five bars")
        XCTAssertTrue(app.buttons["detail-effort-high"].firstMatch.exists, "not three bars")
    }

    @MainActor
    func testATaskStops() throws {
        let app = openAgent()
        let stop = app.buttons["detail-stop-t_run"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "no stop button on a phone")
        attach(app, "tasks")
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5), "the task is still there")
        XCTAssertTrue(app.buttons["detail-stop-t_sub"].firstMatch.exists, "the other one went too")
    }

    /// Three and 还有 N 个, which opens the rest in place.
    @MainActor
    func testManyTasksUnfold() throws {
        let app = openAgent(["-demoState", "detailMany"])
        let more = app.buttons["detail-more-tasks"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no 还有 N 个")
        XCTAssertFalse(app.buttons["detail-stop-t_m4"].exists)
        more.tap()
        XCTAssertTrue(app.buttons["detail-stop-t_m4"].firstMatch.waitForExistence(timeout: 5), "the rest didn't unfold")
        attach(app, "many")
    }

    @MainActor
    func testRenaming() throws {
        let app = openAgent()
        app.buttons["detail-rename"].firstMatch.tap()
        let field = app.textFields["detail-name-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field")
        XCTAssertEqual(field.value as? String, "网站帮手")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        field.typeText("官网\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        let renamed = NSPredicate(format: "label == %@", "官网")
        expectation(for: renamed, evaluatedWith: app.buttons["detail-rename"].firstMatch)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testHistoryAndBack() throws {
        let app = openAgent()
        app.buttons["detail-past-tasks"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["历史"].waitForExistence(timeout: 5), "历史 didn't open")
        XCTAssertTrue(app.staticTexts["跑全部测试"].firstMatch.waitForExistence(timeout: 5), "nothing in it")
        attach(app, "history")
        app.navigationBars["历史"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["detail-model"].firstMatch.waitForExistence(timeout: 5), "not back on the tiles")
    }

    /// 归档 is asked where it is, and 算了 puts it away.
    @MainActor
    func testArchiveIsAskedAndPutAway() throws {
        let app = openAgent()
        let end = app.buttons["detail-end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5) && end.isHittable, "no 归档")
        end.tap()
        let cancel = app.buttons["detail-ask-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "not asked")
        XCTAssertTrue(app.buttons["detail-ask-confirm"].firstMatch.isHittable, "its button is out of reach")
        attach(app, "archive-asked")
        cancel.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5), "not put away")
    }

    @MainActor
    func testTheAssistantsGoalsAndSettings() throws {
        let app = launch()
        let orb = app.buttons["title-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 15))
        orb.tap()
        let goals = app.buttons["detail-timers"].firstMatch
        XCTAssertTrue(goals.waitForExistence(timeout: 5), "no 目标")
        XCTAssertTrue(goals.label.contains("1"), "how many wait on the owner isn't on it: \(goals.label)")
        attach(app, "assistant")
        goals.tap()
        XCTAssertTrue(app.navigationBars["目标"].waitForExistence(timeout: 5), "目标 didn't open")
        XCTAssertTrue(app.staticTexts["邮箱清零"].firstMatch.waitForExistence(timeout: 5), "the goals aren't there")
        attach(app, "goals")
        app.navigationBars["目标"].buttons.firstMatch.tap()
        let settings = app.buttons["detail-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["detail-language"].firstMatch.waitForExistence(timeout: 5), "no 语言 in 设置")
        XCTAssertTrue(app.buttons["洋红"].firstMatch.exists, "no colors in 设置")
        attach(app, "settings")
        app.buttons["detail-name"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["名字和颜色"].waitForExistence(timeout: 5), "名字 didn't open the editor")
    }

    // MARK: helpers

    /// 网站帮手's page with its details open.
    @MainActor
    private func openAgent(_ args: [String] = []) -> XCUIApplication {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"] + args)
        let drop = app.buttons["title-capsule"].firstMatch
        XCTAssertTrue(drop.waitForExistence(timeout: 15), "no indicator on the agent's page")
        drop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent-detail"].firstMatch.waitForExistence(timeout: 5), "the details didn't open")
        return app
    }

    @MainActor
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"] + args
        app.launch()
        return app
    }

    @MainActor
    private func selected(_ bar: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: bar)], timeout: 5) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
