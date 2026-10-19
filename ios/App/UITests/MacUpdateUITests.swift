#if targetEnvironment(macCatalyst)
import XCTest

/// The Mac app's update hint: with the computer reporting a newer version
/// (`-demoHostVersion`) the sidebar shows one quiet capsule with 下载 and a
/// close; closing it keeps it away. The plain demo shows nothing.
///
/// Run like MacLibraryUITests (the screen must be unlocked), with
/// `-only-testing:PaloAllyUITests/MacUpdateUITests`.
final class MacUpdateUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                "-demoWindow", "1300x850"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testANewerHostShowsOneHintThatCloses() throws {
        // A version of its own each run: closing one is remembered between runs.
        let version = "99.\(Int(Date().timeIntervalSince1970)).0"
        let app = launch(["-demoHostVersion", version])
        defer { app.terminate() }
        let hint = app.descendants(matching: .any)["mac-update-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 30), "no update hint in the sidebar")
        XCTAssertTrue(app.buttons["mac-update-download"].exists)
        XCTAssertTrue(app.staticTexts["Mac 版有新版本 \(version)"].exists)
        app.buttons["mac-update-dismiss"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: hint)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testThePlainDemoShowsNoHint() throws {
        let app = launch([])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["右侧栏"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["mac-update-hint"].exists)
    }
}
#endif
