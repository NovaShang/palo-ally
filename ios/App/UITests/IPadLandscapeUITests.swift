import XCTest

/// iPad screenshots in landscape (simctl can't rotate): a few demo pages,
/// the sidebar shown or put away. Each attaches a screenshot.
final class IPadLandscapeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    @MainActor func testLandscapeShots() throws {
        let pages: [(String, [String])] = [
            ("workspace-hidden", ["-demoScreen", "workspace", "-demoSidebar", "hidden"]),
            ("workspace-sidebar", ["-demoScreen", "workspace"]),
            ("pal-hidden", ["-demoScreen", "pal", "-demoSidebar", "hidden"]),
            ("palo-hidden", ["-demoSidebar", "hidden"]),
            ("voice-hidden", ["-demoScreen", "voice", "-demoSidebar", "hidden"]),
            ("workspace-hidden-dark", ["-demoScreen", "workspace", "-demoSidebar", "hidden", "-demoAppearance", "dark"]),
        ]
        XCUIDevice.shared.orientation = .landscapeLeft
        for (name, args) in pages {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-demo", "YES"] + args
            app.launch()
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(6)
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = name
            a.lifetime = .keepAlways
            add(a)
            app.terminate()
        }
    }
}
