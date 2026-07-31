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

    // MARK: - Detail view (read-first transaction detail), light + dark

    func testDetail_Light() { captureDetail(appearance: "light") }
    func testDetail_Dark() { captureDetail(appearance: "dark") }

    private func captureDetail(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser",
            "-modelAbsent", "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        selectFinancesTab(app)
        // The taller metal hero + chart cards push the transaction list well below
        // the fold, and List rows are lazily rendered (absent from the tree until
        // near-visible). Scroll — from BELOW the interactive chart so the drag
        // isn't swallowed by the chart's selection gesture — until the `benzină`
        // row enters the tree, then until it's hittable, then tap it.
        let row = app.staticTexts["benzină"]
        var scrolls = 0
        while !row.exists && scrolls < 10 { scrollListUp(app); scrolls += 1 }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a seeded transaction row should exist")
        scrolls = 0
        while !row.isHittable && scrolls < 6 { scrollListUp(app); scrolls += 1 }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.amount"].waitForExistence(timeout: 15),
                      "the detail hero amount should appear")
        snapshot(app, name: "\(appearance)-detail")
    }

    /// A big upward drag starting below the chart region, so it scrolls the list
    /// rather than triggering the chart's touch-selection gesture.
    private func scrollListUp(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
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
