import XCTest

/// 设置 on an iPhone simulator: tapping 设备编号 copies the whole id and says
/// 已复制 for a moment; the row keeps showing the short form. A phone never
/// shows the Mac app's update hint, even when the computer is ahead.
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTappingTheDeviceIDCopiesIt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES",
                                "-demoScreen", "settings", "-demoHostVersion", "9.9.9"]
        app.launch()

        let row = app.buttons["settings-device-id"]
        var tries = 0
        while !row.isHittable, tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no 设备编号 row")
        XCTAssertTrue(row.label.contains("设备编号"))
        row.tap()
        // The button's label is its row's words together.
        let copied = NSPredicate(format: "label CONTAINS %@", "已复制")
        expectation(for: copied, evaluatedWith: row)
        waitForExpectations(timeout: 3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-device-id-copied"
        shot.lifetime = .keepAlways
        add(shot)
        // Back to the short form a moment later.
        expectation(for: NSPredicate(format: "NOT (label CONTAINS %@)", "已复制"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(row.label.contains("设备编号"))

        XCTAssertFalse(app.buttons["settings-mac-update"].exists, "the Mac's update row showed on a phone")
        XCTAssertFalse(app.buttons["有新版本 9.9.9 · 下载"].exists)
    }
}
