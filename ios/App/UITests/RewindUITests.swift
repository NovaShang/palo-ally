import XCTest

/// 回到这里重来 (docs/rewind-prd.md) against the demo host on an iPhone
/// simulator, with real touches: a long press on the owner's own message has
/// it in its menu; it's asked in place of the composer (算了 leaves
/// everything as it was); 重来 takes that message and the ones after it out
/// and puts its words back in the composer, which takes the keyboard. In a
/// Pal the files can go back too.
final class RewindUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGoingBackInTheAssistantsConversation() throws {
        let app = launch([])
        let mine = text(app, "周末提醒我给妈妈打电话")
        XCTAssertTrue(mine.waitForExistence(timeout: 15), "the conversation didn't load")
        let later = text(app, "周六上午 10 点提醒你")
        XCTAssertTrue(later.exists)
        bringIntoView(app, mine)

        // 算了: nothing changes.
        openRewind(app, on: mine)
        tapItem(app, "算了")
        XCTAssertTrue(waitGone(app.descendants(matching: .any)["rewindPanel"]), "算了 didn't close it")
        XCTAssertTrue(later.exists && mine.exists)

        openRewind(app, on: mine)
        XCTAssertTrue(text(app, "之后的对话会被撤回，已经做过的事不会撤销。").exists, "the panel doesn't say what happens")
        XCTAssertFalse(app.descendants(matching: .any)["rewindRestoreFiles"].exists, "the assistant has no files to restore")
        attach(app, "rewind-palo-asked")
        app.buttons["rewindConfirm"].firstMatch.tap()

        XCTAssertTrue(waitGone(later), "what came after is still there")
        let field = app.descendants(matching: .any)["composerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no composer after going back")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "周末提醒我给妈妈打电话"), evaluatedWith: field)
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        // Only the composer has its words now; what came before is still there.
        XCTAssertTrue(text(app, "帮我把下周去上海的机票和酒店比较一下").exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "周末提醒我给妈妈打电话")).count, 0)
        attach(app, "rewind-palo-done")
    }

    @MainActor
    func testGoingBackInAPalWithItsFiles() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-site"])
        XCTAssertTrue(app.navigationBars.staticTexts["网站帮手"].waitForExistence(timeout: 15), "the Pal's page didn't open")
        let mine = text(app, "先别管登录页，把列表页做完")
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "its conversation didn't load")
        let later = text(app, "列表页做完了，跑一下构建")
        XCTAssertTrue(later.exists)
        // The assistant's words to it aren't the owner's: no 回到这里重来 there.
        let palo = text(app, "设计稿在 notes/设计/列表页.md")
        XCTAssertTrue(palo.exists)
        bringIntoView(app, palo)
        palo.press(forDuration: 1.2)
        XCTAssertTrue(menuItem(app, "复制").waitForExistence(timeout: 5), "no menu on the assistant's words")
        XCTAssertFalse(menuItem(app, "回到这里重来").exists, "offered on words that aren't the owner's")
        menuItem(app, "复制").tap()

        bringIntoView(app, mine)
        openRewind(app, on: mine)
        let files = app.descendants(matching: .any)["rewindRestoreFiles"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "no 代码也恢复到那时 though the files can go back")
        XCTAssertEqual(files.value as? String, "0", "代码也恢复到那时 isn't off at first")
        // Its card is waiting on the owner: 重来 stops it first.
        XCTAssertTrue(text(app, "它还在忙，重来会先停下这一轮").exists, "the panel doesn't say it stops the turn first")
        // The switch itself, at the row's trailing end.
        files.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(files.value as? String, "1", "代码也恢复到那时 didn't turn on")
        attach(app, "rewind-pal-asked")
        app.buttons["rewindConfirm"].firstMatch.tap()

        XCTAssertTrue(waitGone(later), "what came after is still there")
        let field = app.descendants(matching: .any)["composerField"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "先别管登录页，把列表页做完"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(text(app, "列表要能按日期排序").exists, "what came before went too")
        // Its process ended: its card waiting on the owner went with the turn.
        XCTAssertTrue(waitGone(text(app, "运行一条命令")), "its card is still there")
        attach(app, "rewind-pal-done")
    }

    @MainActor
    func testAPalsFirstMessageCantTakeTheFilesBack() throws {
        let app = launch(["-demoScreen", "pal", "-demoPal", "pal-notes"])
        let mine = text(app, "每周把新笔记归类，补上标签")
        XCTAssertTrue(mine.waitForExistence(timeout: 15), "its conversation didn't load")
        bringIntoView(app, mine)
        openRewind(app, on: mine)
        XCTAssertTrue(text(app, "这一步之前的代码没法恢复").waitForExistence(timeout: 5), "doesn't say the files can't go back")
        XCTAssertFalse(app.descendants(matching: .any)["rewindRestoreFiles"].exists)
        tapItem(app, "算了")
    }

    // MARK: helpers

    /// Scrolls the conversation back until the element is on screen.
    @MainActor
    private func bringIntoView(_ app: XCUIApplication, _ e: XCUIElement) {
        for _ in 0..<12 where !e.isHittable {
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(e.isHittable, "couldn't bring it into view")
    }

    /// A menu's item: a menu item or a button, whichever the system made it.
    @MainActor
    private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let item = app.menuItems[title].firstMatch
        return item.exists ? item : app.buttons[title].firstMatch
    }

    @MainActor
    private func tapItem(_ app: XCUIApplication, _ title: String) {
        app.buttons[title].firstMatch.tap()
    }

    @MainActor
    private func openRewind(_ app: XCUIApplication, on bubble: XCUIElement) {
        bubble.press(forDuration: 1.2)
        XCTAssertTrue(app.menuItems["回到这里重来"].firstMatch.waitForExistence(timeout: 5) || app.buttons["回到这里重来"].firstMatch.exists,
                      "no 回到这里重来 in the owner's message menu")
        menuItem(app, "回到这里重来").tap()
        XCTAssertTrue(app.descendants(matching: .any)["rewindPanel"].waitForExistence(timeout: 5), "not asked in place of the composer")
        XCTAssertTrue(app.buttons["rewindConfirm"].exists && app.buttons["算了"].exists)
    }

    @MainActor
    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

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
        app.launchArguments += ["-demo", "YES"] + args
        app.launch()
        return app
    }
}
