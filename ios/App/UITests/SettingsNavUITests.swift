import XCTest

/// The list's 设置 opens Settings (phones).
final class SettingsNavUITests: XCTestCase {
    @MainActor func testListSettingsOpens() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["title-orb"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let gear = app.buttons["sidebar-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        sleep(2)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "after-settings"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "设置 didn't open")
    }
}
