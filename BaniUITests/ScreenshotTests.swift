import XCTest

/// Captures the design-review matrix in BOTH light and dark. Launches with seeded
/// in-memory sample data + a forced RuleBasedParser + the Whisper model absent, so
/// the run is deterministic and the first-launch download screen never appears.
/// CI exports the attachments as the `screenshots` artifact.
///
/// v2 teardown tab order: 0 = Raport, 1 = Log, 2 = Projects, 3 = Settings. Log is
/// the launch tab; the old Finances screen is a drill-down inside the Raport hub.
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

        // Select tabs by INDEX, not localized label — the shared simulator can carry
        // a non-English language over from an earlier test, which would make a label
        // lookup silently miss. v2 order: 0 = Raport, 1 = Log, 2 = Projects, 3 = Settings.
        tabBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["raport.hub.root"].waitForExistence(timeout: 10))
        snapshot(app, name: "\(appearance)-raport")

        tabBar.buttons.element(boundBy: 2).tap()
        snapshot(app, name: "\(appearance)-projects")

        tabBar.buttons.element(boundBy: 3).tap()
        snapshot(app, name: "\(appearance)-settings")

        // The demoted Finances screen — reached as a drill-down from the Raport hub.
        tabBar.buttons.element(boundBy: 0).tap()
        let allTx = app.descendants(matching: .any)["raport.allTransactions"]
        var swipes = 0
        while !allTx.isHittable && swipes < 8 { app.swipeUp(); swipes += 1 }
        if allTx.exists {
            allTx.tap()
            snapshot(app, name: "\(appearance)-finances")
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
