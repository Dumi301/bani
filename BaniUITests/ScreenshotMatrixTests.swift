import XCTest

/// Extra design-review screenshots (A4 + B5), graded visually and non-blocking
/// (not `ManualEntryUITests`):
///   • the interactive bar chart with a selected bar + annotation (light + dark),
///   • the app in Romanian (Log + Finances), checked for truncation/overflow.
/// Tabs are selected by index so the capture is locale-agnostic.
final class ScreenshotMatrixTests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func snapshot(_ app: XCUIApplication, name: String) {
        // Let spring transitions / chart annotation settle for a clean frame.
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func selectFinancesTab(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
        // Finances is the middle (2nd) tab — index is stable across languages.
        tabBar.buttons.element(boundBy: 1).tap()
    }

    // MARK: - A4: interactive bar chart (selected bar + annotation)

    func testBarsChartAnnotation_Light() { captureBars(appearance: "light") }
    func testBarsChartAnnotation_Dark() { captureBars(appearance: "dark") }

    private func captureBars(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-uiTestBars", "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        selectFinancesTab(app)
        // The bars chart opens pre-selected with its annotation shown (-uiTestBars).
        XCTAssertTrue(app.descendants(matching: .any)["finances.barsChart"].waitForExistence(timeout: 10),
                      "the bar chart should be visible")
        snapshot(app, name: "\(appearance)-finances-bars-annotation")
    }

    // MARK: - B5: Romanian (Log + Finances, light)

    func testRomanian_LogAndFinances() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-appLanguage", "ro", "-appearance", "light",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        snapshot(app, name: "ro-log")
        selectFinancesTab(app)
        snapshot(app, name: "ro-finances")
    }

    // MARK: - B1 density (Log + Finances donut at Airy and Dense, light)

    func testDensity_Airy() { captureDensity("airy") }
    func testDensity_Dense() { captureDensity("dense") }

    private func captureDensity(_ scale: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-appearance", "light", "-designScale", scale,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        snapshot(app, name: "light-log-\(scale)")
        selectFinancesTab(app)
        snapshot(app, name: "light-finances-\(scale)")
    }
}
