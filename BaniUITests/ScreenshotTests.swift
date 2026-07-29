import XCTest

/// Captures the full design-review matrix: Log / Finances / Settings in BOTH
/// light and dark (3 × 2 = 6 screenshots). Launches with seeded in-memory
/// sample data + a forced RuleBasedParser + the Whisper model absent, so the
/// run is deterministic and the first-launch download screen never appears.
/// CI exports the attachments as the `screenshots` artifact.
final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScreens_Light() {
        captureAllScreens(appearance: "light")
    }

    func testScreens_Dark() {
        captureAllScreens(appearance: "dark")
    }

    private func captureAllScreens(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-seedSampleData",
            "-seedRate",
            "-forceRuleParser",
            "-modelAbsent",
            "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // Log tab is selected on launch.
        snapshot(app, name: "\(appearance)-log")

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")

        selectTab(tabBar, "Finances")
        snapshot(app, name: "\(appearance)-finances")

        selectTab(tabBar, "Settings")
        snapshot(app, name: "\(appearance)-settings")
    }

    private func selectTab(_ tabBar: XCUIElement, _ label: String) {
        let button = tabBar.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        }
    }

    private func snapshot(_ app: XCUIApplication, name: String) {
        // Let spring transitions settle for a clean frame.
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
