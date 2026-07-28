import XCTest

/// Phase-0 minimal screenshot capture (light + dark). Expanded during
/// integration to walk Log / Finances / Settings across both modes.
/// Launches with a forced RuleBasedParser + seeded in-memory sample data.
final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureRootLight() {
        capture(appearance: "light", name: "light-root")
    }

    func testCaptureRootDark() {
        capture(appearance: "dark", name: "dark-root")
    }

    private func capture(appearance: String, name: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-seedSampleData",
            "-forceRuleParser",
            "-modelAbsent",
            "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
