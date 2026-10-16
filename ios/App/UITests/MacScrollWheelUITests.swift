#if targetEnvironment(macCatalyst)
import XCTest

/// Scrolling the Mac app's conversation with a mouse wheel (real scroll-wheel
/// events, not touches): it once seemed frozen, every wheel step undone, and
/// only 回到最新 moved it. The list read the reader's scrolls from the
/// finger and the scroll phase, which a wheel doesn't give, so its scrolls
/// were taken for the layout moving the list and put back: reading back, the
/// held row was scrolled back into place; on the end, the view was pulled
/// back onto it.
///
/// Run on Mac Catalyst under another bundle id, signed to run locally without
/// push, so the installed app and its data are never touched (the screen must
/// be unlocked, and macOS asks once to allow UI automation):
///
///     xcodebuild test -project ios/App/PaloAlly.xcodeproj -scheme PaloAlly \
///       -destination 'platform=macOS,variant=Mac Catalyst' \
///       -only-testing:PaloAllyUITests/MacScrollWheelUITests \
///       'PRODUCT_BUNDLE_IDENTIFIER=$(DEVTEST_ID_$(WRAPPER_EXTENSION))' \
///       DEVTEST_ID_app=com.novashang.paloally.devtest \
///       DEVTEST_ID_xctest=com.novashang.paloally.devtest.uitests \
///       CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
///       CODE_SIGN_ENTITLEMENTS=<PaloAlly.entitlements without aps-environment>
final class MacScrollWheelUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWheelScrollsTheConversationIdle() throws {
        try wheel(["-demoStreamDelay", "600"], streaming: false)
    }

    @MainActor
    func testWheelScrollsTheConversationWhileAReplyStreams() throws {
        try wheel([], streaming: true)
    }

    /// Up from the end, more while reading back, then back down to the end.
    /// A question near the end is the marker: where it is on screen says
    /// where the view is.
    @MainActor
    private func wheel(_ args: [String], streaming: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES", "-demoState", "long"] + args
        app.launch()
        defer { app.terminate() }
        let marker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "第 90 个问题")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "the conversation never appeared")
        let list = app.scrollViews.containing(NSPredicate(format: "label BEGINSWITH %@", "第 90 个问题")).firstMatch
        XCTAssertTrue(list.exists, "no scroll view holds the conversation")
        let jump = app.buttons["jumpToLatest"]
        // Settled on the end (while streaming: the reply has begun, from 4 s).
        sleep(streaming ? 6 : 3)
        XCTAssertFalse(jump.exists, "not on the end to begin with")

        /// Wheel `steps` notches of 60 px (positive: up, toward older).
        func scroll(_ steps: Int, up: Bool) {
            for _ in 0..<steps {
                list.scroll(byDeltaX: 0, deltaY: up ? 60 : -60)
            }
        }
        func y() -> CGFloat { marker.frame.minY }

        // 1. Up from the end: the view moves, and stays.
        let atEnd = y()
        scroll(5, up: true)
        usleep(300_000)
        let up1 = y()
        XCTAssertGreaterThan(up1 - atEnd, 100, "the wheel didn't move the view up from the end")
        sleep(2)
        let rested1 = y()
        XCTAssertEqual(rested1, up1, accuracy: 2, "the view went back after the wheel stopped (it was \(Int(up1 - atEnd)) pt up)")
        XCTAssertTrue(jump.exists, "still following the end after scrolling up")

        // 2. More, reading back: it keeps moving, and stays.
        scroll(5, up: true)
        usleep(300_000)
        let up2 = y()
        XCTAssertGreaterThan(up2 - rested1, 100, "the wheel didn't move the view while reading back")
        sleep(2)
        XCTAssertEqual(y(), up2, accuracy: 2, "the view went back while reading back")

        // 3. Back down past the end: following it again.
        scroll(40, up: false)
        sleep(streaming ? 3 : 2)
        XCTAssertFalse(jump.exists, "回到最新 still shows after scrolling back to the end")
        if !streaming {
            XCTAssertEqual(y(), atEnd, accuracy: 2, "not back on the end")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
#endif
