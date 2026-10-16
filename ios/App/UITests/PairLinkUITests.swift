import XCTest

/// A computer's pairing link (`paloally pair`, or the assistant's pair_link)
/// clicked outside the app, in Safari, Notes, Messages or Mail, while this
/// device already has an assistant (the demo's): the app comes forward on
/// 「添加这台电脑？」, whether it was running or the link launched it.
final class PairLinkUITests: XCTestCase {
    private let link = "paloally://pair?relay=https%3A%2F%2Frelay.example.com&daemon=d-office&code=123456"
        + "&hostkey=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testALinkClickedWhileTheAppRunsAsksToAddTheComputer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 20), "the conversation never appeared")
        // As the system opens it: the app goes to the background and back.
        XCUIDevice.shared.press(.home)
        app.open(try XCTUnwrap(URL(string: link)))
        try confirmShows(in: app)
    }

    @MainActor
    func testALinkThatLaunchesTheAppAsksToAddTheComputer() throws {
        let app = XCUIApplication()
        // The link the app was opened with, as on a cold start.
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES", "-pairLink", link]
        app.launch()
        defer { app.terminate() }
        try confirmShows(in: app)
    }

    @MainActor
    private func confirmShows(in app: XCUIApplication) throws {
        XCTAssertTrue(app.staticTexts["添加这台电脑？"].waitForExistence(timeout: 15), "no 「添加这台电脑？」")
        XCTAssertTrue(app.buttons["添加"].exists, "no 添加")
        // Not now: the pairing screen goes too, nothing was paired. (The
        // dialog is a popover whose cancel is a tap outside it.)
        let notNow = app.buttons["不用"].firstMatch
        if notNow.isHittable { notNow.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        XCTAssertFalse(app.staticTexts["添加这台电脑？"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["取消"].waitForExistence(timeout: 3), "the pairing screen stayed")
    }
}
