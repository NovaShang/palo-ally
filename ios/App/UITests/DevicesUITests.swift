import XCTest

/// 电脑与设备 (docs/devices-prd.md) against the demo host on an iPhone
/// simulator: with one computer the list's first row is just the assistant
/// and the last row is 电脑与设备; with two, the name on the first row is a
/// menu that switches; the page lists the computers and the devices paired
/// with the current one, shows 添加设备's QR code and link, and asks in place
/// before taking a device off (never this one).
final class DevicesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOneComputerShowsNothingMultiHostButTheQuietLastRow() throws {
        let app = launch(["-demoScreen", "list"])
        XCTAssertTrue(app.descendants(matching: .any)["row-palo"].waitForExistence(timeout: 15), "no list")
        XCTAssertFalse(app.buttons["assistant-switcher"].exists, "a switcher with one computer")
        let devices = app.descendants(matching: .any)["row-devices"]
        devices.swipeUpUntilVisible(in: app)
        XCTAssertTrue(devices.exists, "no 电脑与设备 row")
        attach(app, "list-one-host")
    }

    @MainActor
    func testSwitchingAssistantsFromTheListsTopRow() throws {
        let app = launch(["-demoScreen", "list", "-demoHosts", "2"])
        let switcher = app.buttons["assistant-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "no switcher with two computers")
        let before = switcher.label
        switcher.tap()
        let other = app.buttons["switch-demo-2"].exists ? app.buttons["switch-demo-2"] : app.buttons["switch-demo-1"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "the menu doesn't list the assistants")
        XCTAssertTrue(app.buttons["电脑与设备…"].exists, "no 电脑与设备… in the menu")
        attach(app, "list-two-hosts-menu")
        other.tap()
        // The other assistant's conversation opens (phones), and back on the list its name is on top.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        XCTAssertNotEqual(switcher.label, before, "it didn't switch")
    }

    @MainActor
    func testTheDevicesPageAddsWithACodeAndAsksBeforeRemoving() throws {
        let app = launch(["-demoScreen", "devices"])
        XCTAssertTrue(app.navigationBars.staticTexts["电脑与设备"].waitForExistence(timeout: 15), "the page didn't open")
        XCTAssertTrue(text(app, "我的助理").exists)
        XCTAssertTrue(text(app, "连着这台电脑的设备").exists)
        let ipad = app.descendants(matching: .any)["device-dev-ipad"]
        XCTAssertTrue(ipad.waitForExistence(timeout: 10), "the devices didn't load")
        XCTAssertTrue(app.descendants(matching: .any)["device-dev-this"].label.contains("这台"), "this device isn't marked")
        attach(app, "devices-page")

        // This one can't be removed here.
        app.descendants(matching: .any)["device-dev-this"].press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["移除"].waitForExistence(timeout: 2), "this device offers 移除")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()

        // Another one: asked in place first.
        ipad.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["移除"].waitForExistence(timeout: 5), "no 移除 on another device")
        app.buttons["移除"].tap()
        XCTAssertTrue(text(app, "移除「iPad」？").waitForExistence(timeout: 5), "not asked first")
        XCTAssertTrue(ipad.exists, "removed without asking")
        attach(app, "devices-remove-asked")
        app.buttons["移除"].firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: ipad)
        waitForExpectations(timeout: 5)

        // 添加设备: the QR code, the link, the countdown.
        app.buttons["add-device"].tap()
        XCTAssertTrue(app.images["device-qr"].waitForExistence(timeout: 10), "no QR code")
        XCTAssertTrue(text(app, "用另一台设备扫码，或者在那台设备上点开链接").exists)
        XCTAssertTrue(app.staticTexts["invite-expiry"].label.hasPrefix("还剩"), "no countdown")
        XCTAssertTrue(app.buttons["invite-copy"].exists && app.buttons["共享"].exists, "no 拷贝 / 共享")
        attach(app, "devices-add-qr")
    }

    /// Screenshots for review, light and dark: the list with one computer
    /// and with two (its menu open), 电脑与设备, 添加设备, a Pal's [+].
    @MainActor
    func testScreenshotsLightAndDark() throws {
        for look in ["light", "dark"] {
            var app = launch(["-demoScreen", "list", "-demoAppearance", look])
            XCTAssertTrue(app.descendants(matching: .any)["row-palo"].waitForExistence(timeout: 15))
            sleep(2)
            attach(app, "list-one-host-\(look)")
            let devices = app.descendants(matching: .any)["row-devices"]
            devices.swipeUpUntilVisible(in: app)
            sleep(1)
            attach(app, "list-one-host-end-\(look)")
            app.terminate()

            app = launch(["-demoScreen", "list", "-demoHosts", "2", "-demoAppearance", look])
            let switcher = app.buttons["assistant-switcher"]
            XCTAssertTrue(switcher.waitForExistence(timeout: 15))
            sleep(2)
            switcher.tap()
            XCTAssertTrue(app.buttons["电脑与设备…"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "list-two-hosts-menu-\(look)")
            app.terminate()

            app = launch(["-demoScreen", "devices", "-demoHosts", "2", "-demoAppearance", look])
            XCTAssertTrue(app.descendants(matching: .any)["device-dev-ipad"].waitForExistence(timeout: 15))
            sleep(1)
            attach(app, "devices-\(look)")
            app.buttons["add-device"].tap()
            XCTAssertTrue(app.images["device-qr"].waitForExistence(timeout: 10))
            sleep(1)
            attach(app, "devices-add-qr-\(look)")
            app.terminate()

            app = launch(["-demoScreen", "pal", "-demoPal", "pal-site", "-demoAppearance", look])
            let plus = app.buttons["添加照片或文件"].firstMatch
            XCTAssertTrue(plus.waitForExistence(timeout: 15))
            sleep(2)
            plus.tap()
            XCTAssertTrue(app.buttons["照片"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "pal-plus-\(look)")
            app.terminate()
        }
    }

    @MainActor
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

private extension XCUIElement {
    /// Scrolls the app's list up until this is on screen (a few swipes at most).
    @MainActor
    func swipeUpUntilVisible(in app: XCUIApplication) {
        for _ in 0..<6 where !(exists && isHittable) {
            app.swipeUp()
        }
    }
}
