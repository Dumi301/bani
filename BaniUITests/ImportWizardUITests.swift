import XCTest

/// The one-tap import (v1.1 RUN 1): a multi-file import reaches the understanding
/// report with per-file status chips + questions, and the People view renders
/// paid/received/net. Both are non-blocking (not `ManualEntryUITests`) and capture
/// screenshots for visual grading (light + dark). The demoted wizard is no longer
/// auto-driven — it is reachable only from the report's fix-mapping hatch (D5).
final class ImportWizardUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func snapshot(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes { app.swipeUp(); swipes += 1 }
    }

    /// Multi-file import (a Family-B statement + a generic table) reaches the report.
    func testImportReachesUnderstandingReport() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTesting", "-modelAbsent", "-importUITest", "-importReportUITest", "-appearance", appearance]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

            // Settings (v2: 4th tab, index 3 — Raport/Log/Projects/Settings,
            // locale-agnostic) auto-presents the import flow, which — under
            // -importReportUITest — loads the synthetic files straight to the report.
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
            tabBar.buttons.element(boundBy: 3).tap()

            let confirm = app.buttons["import.report.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the understanding report should appear")
            snapshot(app, name: "\(appearance)-import-report")
        }
    }

    /// The People view (grouping → People) renders per-counterparty rows.
    func testPeopleView() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedSampleData", "-seedRate", "-forceRuleParser", "-modelAbsent", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // The Finances surface is now a drill-down inside the Raport hub (v2):
        // Raport tab (index 0) → "All transactions".
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 0).tap()
        let allTx = app.descendants(matching: .any)["raport.allTransactions"]
        XCTAssertTrue(allTx.waitForExistence(timeout: 10), "the All transactions drill-down should exist")
        scrollToHittable(allTx, in: app)
        allTx.tap()

        let grouping = app.segmentedControls["financesGroupingPicker"]
        if !grouping.waitForExistence(timeout: 8) { app.swipeUp() }
        scrollToHittable(grouping, in: app)
        if grouping.exists {
            // Category(0) · Month(1) · Merchant(2) · People(3) — index is locale-agnostic.
            grouping.buttons.element(boundBy: 3).tap()
        }
        snapshot(app, name: "light-people")
    }
}
