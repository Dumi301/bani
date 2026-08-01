import XCTest

/// Drives the Excel/CSV import wizard to the preview step using the bundled CSV
/// fixture (loaded via the `-importUITest` seam, since a UI test can't drive the
/// system document picker). Non-blocking (not `ManualEntryUITests`) and captures
/// mapping + preview screenshots for visual grading.
final class ImportWizardUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func snapshot(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// XCUITest won't auto-scroll for `.tap()`; swipe until the element is hittable.
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    func testWizardReachesPreviewWithCSVFixture() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-modelAbsent", "-importUITest"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // Settings is the 3rd tab (index 2) — locale-agnostic. The wizard
        // auto-presents on the mapping step with the fixture preloaded.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
        tabBar.buttons.element(boundBy: 2).tap()

        let continueButton = app.buttons["import.map.continueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15), "mapping step should appear")
        snapshot(app, name: "import-mapping")

        scrollToHittable(continueButton, in: app)
        XCTAssertTrue(continueButton.isHittable, "continue button should be reachable")
        continueButton.tap()

        let importButton = app.buttons["import.preview.importButton"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 15), "preview step should appear")
        snapshot(app, name: "import-preview")
    }
}
