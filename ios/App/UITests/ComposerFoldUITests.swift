import XCTest

/// Up in the history the composer folds into [+] [↓] [轻点打字，按住说话]
/// (docs/workbench-design/composer-scrolled-up.html): a tap on the capsule
/// opens it in place with the field focused and the conversation where it was;
/// ↓ goes back to the latest with the full composer. Against the demo host
/// on an iPhone simulator.
final class ComposerFoldUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFoldsWhenScrolledUpAndOpensInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES", "-demoState", "long"]
        app.launch()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the conversation never appeared")
        let field = app.descendants(matching: .any)["composerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer at the end")
        let voice = app.descendants(matching: .any)["composerFoldedVoice"]
        let plus = app.descendants(matching: .any)["composerFoldedPlus"]
        let jump = app.buttons["jumpToLatest"]
        XCTAssertFalse(voice.exists, "folded at the end")
        snap(app, "1-at-the-end")

        // Up into the history: three buttons, no capsule.
        scrollUp(list)
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "didn't fold after scrolling up\n\(app.debugDescription)")
        XCTAssertTrue(plus.exists, "no + when folded")
        XCTAssertTrue(jump.exists, "no ↓ when folded")
        XCTAssertFalse(field.exists, "the field still shows when folded")
        sleep(1) // the fling and the fold settle
        // The ↓ is the smaller one, the two sides as tall as each other.
        XCTAssertEqual(plus.frame.height, voice.frame.height, accuracy: 1)
        XCTAssertLessThan(jump.frame.height, voice.frame.height * 0.8)
        XCTAssertEqual(app.buttons.matching(identifier: "jumpToLatest").count, 1, "a second, floating ↓ while folded")
        snap(app, "2-folded")

        // ↓: back to the latest, the full composer back.
        jump.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "↓ didn't bring the composer back")
        sleep(1)
        XCTAssertFalse(voice.exists, "still folded at the end")
        XCTAssertFalse(jump.exists, "↓ still shows at the end")
        snap(app, "3-back-at-the-end")

        // Up again; a message in the upper part of the view, to see that it stays put.
        scrollUp(list)
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "didn't fold the second time")
        sleep(1)
        let found = try visibleText(in: list)
        XCTAssertNotNil(found, "no message text in view: \((try? texts(in: list).map { "\(Int($0.minY)) \($0.label.prefix(8))" }) ?? [])")
        let anchorLabel = found?.label ?? ""
        let before = found?.minY ?? 0

        // Tap the 「轻点打字，按住说话」 capsule: open in place, the field focused.
        voice.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the capsule tap didn't open the composer")
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 4)
        sleep(1)
        snap(app, "4-opened-in-place")
        // The same message, where it was (not scrolled to the end).
        // The whole app: the keyboard has scroll views of its own.
        let same = try texts(in: app).filter { $0.label == anchorLabel }
        let after = same.min { abs($0.minY - before) < abs($1.minY - before) }
        XCTAssertNotNil(after, "the message read before the tap is gone: the list moved (\(anchorLabel.prefix(20)))")
        if let after {
            XCTAssertEqual(after.minY, before, accuracy: 2, "the list moved when the composer opened")
        }
        XCTAssertFalse(voice.exists, "still folded while writing")
    }

    @MainActor
    private func scrollUp(_ list: XCUIElement) {
        list.swipeDown(velocity: .fast)
        list.swipeDown(velocity: .fast)
    }

    /// The texts in the list, with where they are (one snapshot: fast).
    @MainActor
    private func texts(in list: XCUIElement) throws -> [(label: String, minY: CGFloat)] {
        var out: [(label: String, minY: CGFloat)] = []
        func walk(_ e: XCUIElementSnapshot) {
            if e.elementType == .staticText, !e.label.isEmpty, e.frame.height > 10 { out.append((e.label, e.frame.minY)) }
            e.children.forEach(walk)
        }
        walk(try list.snapshot())
        return out
    }

    /// A message text a little above the middle of the list.
    @MainActor
    private func visibleText(in list: XCUIElement) throws -> (label: String, minY: CGFloat)? {
        let lf = list.frame
        return try texts(in: list).filter { $0.minY > lf.minY + 60 && $0.minY < lf.maxY - 150 }.min { abs($0.minY - lf.midY + 100) < abs($1.minY - lf.midY + 100) }
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-fold-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
