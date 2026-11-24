import XCTest

/// 待办 (docs/workbench-design/backlog-v2.html) on an iPhone simulator
/// against the demo host, with real taps and typing: ▶ starts one, the
/// circle says done and 撤回 puts it back, the words change in place, the
/// field adds, a swipe and the open row's 🗑 delete (and 撤回).
final class BacklogUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testStart() throws {
        let app = launch()
        let row = row(app, "b_lazy")
        row.buttons["backlog-start"].firstMatch.tap()
        XCTAssertTrue(text(app, "交给了网站帮手").waitForExistence(timeout: 3), "nothing says who has it")
        // The words are on their way: no 撤回.
        XCTAssertFalse(app.buttons["backlog-undo"].exists)
        XCTAssertTrue(wait(5) { row.exists && !row.buttons["backlog-start"].exists }, "not being done")
        // A tap on it goes to its agent.
        row.tap()
        XCTAssertTrue(wait(5) { !app.descendants(matching: .any)["backlog-list"].exists }, "the pane stayed")
    }

    @MainActor
    func testDoneAndUndo() throws {
        let app = launch()
        let row = row(app, "b_404")
        let top = row.frame.minY
        row.buttons["backlog-check"].firstMatch.tap()
        let undo = app.buttons["backlog-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no 撤回")
        XCTAssertTrue(wait(3) { !row.exists }, "still in line")
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "撤回 didn't put it back")
        XCTAssertTrue(wait(3) { abs(row.frame.minY - top) < 2 }, "not where it was")
        XCTAssertFalse(undo.exists)
        // 做完 unfolds; the tick puts one back at the end of the line.
        row.buttons["backlog-check"].firstMatch.tap()
        let toggle = app.descendants(matching: .any)["backlog-done-toggle"].firstMatch
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        toggle.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "not among the done ones")
    }

    @MainActor
    func testEditTheWords() throws {
        let app = launch()
        let row = row(app, "b_radius")
        row.buttons["backlog-words"].firstMatch.tap()
        let words = field(app, "backlog-edit-text")
        XCTAssertTrue(words.waitForExistence(timeout: 5), "didn't open")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
        words.typeText("和阴影")
        // Return saves and closes.
        words.typeText("\n")
        XCTAssertTrue(wait(5) { !words.exists }, "didn't close")
        XCTAssertTrue(text(app, "统一按钮圆角和阴影").waitForExistence(timeout: 5), "the words are lost")
        // The note, and a tap elsewhere.
        row.buttons["backlog-words"].firstMatch.tap()
        let note = field(app, "backlog-edit-note")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("先问设计")
        // Another row's words: that one opens, this one is saved and closed.
        self.row(app, "b_lazy").buttons["backlog-words"].firstMatch.tap()
        XCTAssertTrue(text(app, "先问设计").waitForExistence(timeout: 5), "the note is lost")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "backlog-edit-text").count, 1, "two rows open")
    }

    @MainActor
    func testEditsOutliveThePane() throws {
        let app = launch()
        row(app, "b_radius").buttons["backlog-words"].firstMatch.tap()
        let words = field(app, "backlog-edit-text")
        XCTAssertTrue(words.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        words.typeText("和阴影")
        // Straight away, before the pause is up.
        app.buttons["关闭侧栏"].firstMatch.tap()
        openPane(app)
        XCTAssertTrue(text(app, "统一按钮圆角和阴影").waitForExistence(timeout: 5), "the words are lost")
    }

    @MainActor
    func testAdd() throws {
        let app = launch("backlogMany")
        let add = field(app, "backlog-add")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        add.typeText("新加的一件\n")
        XCTAssertTrue(text(app, "新加的一件").waitForExistence(timeout: 5), "not added")
        XCTAssertTrue(wait(3) { self.text(app, "新加的一件").isHittable }, "the list didn't go to it")
        // Typing on: the next one.
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard left")
        add.typeText("再来一件\n")
        XCTAssertTrue(text(app, "再来一件").waitForExistence(timeout: 5), "the second isn't added")
    }

    @MainActor
    func testDelete() throws {
        let app = launch()
        // Swiped away, and back.
        let row = row(app, "b_404")
        row.swipeLeft()
        app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(wait(3) { !row.exists }, "still there")
        app.buttons["backlog-undo"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "撤回 didn't put it back")
        // From the open row.
        row.buttons["backlog-words"].firstMatch.tap()
        let trash = app.buttons["backlog-remove"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()
        XCTAssertTrue(wait(3) { !row.exists }, "still there")
        XCTAssertTrue(app.buttons["backlog-undo"].firstMatch.exists)
        // Left alone, 撤回 goes away and it's gone.
        XCTAssertTrue(wait(6) { !app.buttons["backlog-undo"].exists })
        XCTAssertFalse(row.exists)
    }

    @MainActor
    func testEmpty() throws {
        let app = launch("backlogEmpty")
        XCTAssertTrue(app.staticTexts["没有待办"].waitForExistence(timeout: 5))
        let add = field(app, "backlog-add")
        add.tap()
        add.typeText("第一件\n")
        XCTAssertTrue(text(app, "第一件").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["没有待办"].exists)
    }

    // MARK: helpers

    @MainActor
    private func launch(_ state: String = "backlogDoing") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-demoScreen", "pal", "-demoPal", "pal-site", "-demoState", state,
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openPane(app)
        return app
    }

    @MainActor
    private func openPane(_ app: XCUIApplication) {
        let button = app.buttons["page-files"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no right-pane button")
        button.tap()
        let tab = app.buttons["pane-tab-backlog"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no 待办")
        tab.tap()
        XCTAssertTrue(field(app, "backlog-add").waitForExistence(timeout: 5), "待办 didn't open")
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let row = app.descendants(matching: .any)["backlog-row-\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no row \(id)")
        return row
    }

    @MainActor
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id)
            .matching(NSPredicate(format: "elementType IN %@", [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue]))
            .firstMatch
    }

    @MainActor
    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    @MainActor
    private func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
}
