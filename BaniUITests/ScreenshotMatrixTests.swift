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
        // v1.2a order: 0 = Log, 1 = Projects, 2 = Finances, 3 = Settings.
        // Index is stable across languages.
        tabBar.buttons.element(boundBy: 2).tap()
    }

    /// Select the v1.2a Projects tab (index 1) for the Projects screenshot matrix.
    private func selectProjectsTab(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
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

    // MARK: - v1.2a Projects tab + project dashboard (non-blocking grade)

    func testProjects_Light() { captureProjects(appearance: "light") }
    func testProjects_Dark() { captureProjects(appearance: "dark") }

    private func captureProjects(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        selectProjectsTab(app)
        // The portfolio header + project cards (seeded projects: Manhattan, Renovare).
        XCTAssertTrue(app.descendants(matching: .any)["portfolio.netPosition"].waitForExistence(timeout: 10),
                      "the portfolio header should be visible")
        snapshot(app, name: "\(appearance)-projects")

        // Into the first project's dashboard (donut scoped by projectID).
        let card = app.descendants(matching: .any).matching(identifier: "project.card").firstMatch
        if card.waitForExistence(timeout: 8) {
            card.tap()
            snapshot(app, name: "\(appearance)-project-dashboard")
        }
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
