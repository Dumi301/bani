import XCTest

/// Extra design-review screenshots (graded visually, non-blocking — NOT
/// `ManualEntryUITests`):
///   • the v2 Raport hub (dark + light) — the flagship teardown surface,
///   • the interactive bar chart with a selected bar + annotation (light + dark),
///   • the app in Romanian (Log + Raport hub + Finances drill-down),
///   • Projects tab + dashboard, and the B1 density matrix.
/// Tabs are selected by INDEX so capture is locale-agnostic. v2 tab order:
/// 0 = Raport, 1 = Log, 2 = Projects, 3 = Settings (Log is the launch tab).
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

    private func selectTab(_ app: XCUIApplication, index: Int) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
        tabBar.buttons.element(boundBy: index).tap()
    }

    /// The demoted Finances surface is now a drill-down inside the Raport hub:
    /// Raport tab (index 0) → the "All transactions" row.
    private func openFinances(_ app: XCUIApplication) {
        selectTab(app, index: 0)
        let allTx = app.descendants(matching: .any)["raport.allTransactions"]
        XCTAssertTrue(allTx.waitForExistence(timeout: 10), "the All transactions drill-down should exist")
        var swipes = 0
        while !allTx.isHittable && swipes < 8 { app.swipeUp(); swipes += 1 }
        allTx.tap()
    }

    // MARK: - v2 flagship: the Raport hub (dark + light)

    func testRaportHub_Light() { captureRaportHub(appearance: "light") }
    func testRaportHub_Dark() { captureRaportHub(appearance: "dark") }

    private func captureRaportHub(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        selectTab(app, index: 0)   // Raport
        XCTAssertTrue(app.descendants(matching: .any)["raport.hub.root"].waitForExistence(timeout: 10),
                      "the Raport hub should be visible")
        snapshot(app, name: "\(appearance)-raport-hub")
    }

    // MARK: - Interactive bar chart (selected bar + annotation)

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
        openFinances(app)
        // The bars chart opens pre-selected with its annotation shown (-uiTestBars).
        XCTAssertTrue(app.descendants(matching: .any)["finances.barsChart"].waitForExistence(timeout: 10),
                      "the bar chart should be visible")
        snapshot(app, name: "\(appearance)-finances-bars-annotation")
    }

    // MARK: - Romanian (Log + Raport hub + Finances drill-down, light)

    func testRomanian_LogRaportFinances() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-appLanguage", "ro", "-appearance", "light",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        snapshot(app, name: "ro-log")
        selectTab(app, index: 0)
        XCTAssertTrue(app.descendants(matching: .any)["raport.hub.root"].waitForExistence(timeout: 10))
        snapshot(app, name: "ro-raport")
        let allTx = app.descendants(matching: .any)["raport.allTransactions"]
        var swipes = 0
        while !allTx.isHittable && swipes < 8 { app.swipeUp(); swipes += 1 }
        if allTx.exists { allTx.tap() }
        snapshot(app, name: "ro-finances")
    }

    // MARK: - Projects tab + project dashboard (non-blocking grade)

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
        selectTab(app, index: 2)   // Projects (v2: index 2)
        XCTAssertTrue(app.descendants(matching: .any)["portfolio.netPosition"].waitForExistence(timeout: 10),
                      "the portfolio header should be visible")
        snapshot(app, name: "\(appearance)-projects")

        let card = app.descendants(matching: .any).matching(identifier: "project.card").firstMatch
        if card.waitForExistence(timeout: 8) {
            card.tap()
            snapshot(app, name: "\(appearance)-project-dashboard")
        }
    }

    // MARK: - B1 density (Log + Finances drill-down at Airy and Dense, light)

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
        openFinances(app)
        snapshot(app, name: "light-finances-\(scale)")
    }
}
