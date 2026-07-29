import XCTest

/// D3 — with seeded data and a cached BNR rate, tapping a Finances row opens the
/// read-first detail view (amount, context, category, currency conversion), and
/// its Edit button opens the pre-filled edit sheet. Runs with the Whisper model
/// absent so the first-launch download screen never blocks the tabs.
final class TransactionDetailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-seedSampleData",
            "-seedRate",
            "-forceRuleParser",
            "-modelAbsent",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    func testRowTapOpensDetailThenEditIsPrefilled() throws {
        let app = launchApp()

        // Go to Finances.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
        tabBar.buttons["Finances"].tap()

        // Tap the first seeded transaction row.
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "a seeded transaction row should be visible")
        firstRow.tap()

        // Detail view: amount, context, category, and the conversion line
        // (present because -seedRate cached a BNR rate).
        let amount = app.descendants(matching: .any)["detail.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "detail view should show the amount hero")
        XCTAssertTrue(app.descendants(matching: .any)["detail.contextTag"].exists, "detail should show the context tag")
        XCTAssertTrue(app.descendants(matching: .any)["detail.categoryChip"].exists, "detail should show the category chip")
        XCTAssertTrue(app.descendants(matching: .any)["detail.conversion"].waitForExistence(timeout: 5),
                      "detail should show the other-currency conversion line at the cached BNR rate")

        // Edit opens the sheet, pre-filled — the amount field is never blank.
        app.buttons["detail.editButton"].tap()

        let amountField = app.textFields["editAmountField"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "Edit should open the edit sheet")
        let value = (amountField.value as? String) ?? ""
        XCTAssertFalse(value.isEmpty, "the edit amount field must be pre-filled, never blank")
        XCTAssertNotEqual(value, "0", "the edit amount field must carry the real amount")

        XCTAssertTrue(app.buttons["editSaveButton"].exists, "the pre-filled edit sheet should offer Save")
    }
}
