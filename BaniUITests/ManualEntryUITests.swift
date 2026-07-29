import XCTest

/// Proves the manual-entry path works fully with the Whisper model absent
/// (`-modelAbsent`) — manual entry has zero Whisper dependency by design.
/// Drives: open `ManualEntrySheet` → amount → currency → description →
/// context → save → sheet dismisses back to the Log screen.
final class ManualEntryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-modelAbsent"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    func testManualEntrySavesWithModelAbsent() throws {
        let app = launchApp()

        let manualEntryButton = app.buttons["logView.manualEntryButton"]
        XCTAssertTrue(manualEntryButton.waitForExistence(timeout: 5))
        manualEntryButton.tap()

        let amountField = app.textFields["manualEntry.amountField"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("42.50")

        let currencyToggle = app.segmentedControls["manualEntry.currencyToggle"]
        XCTAssertTrue(currencyToggle.exists)
        currencyToggle.buttons["EUR"].tap()

        let descriptionField = app.textFields["manualEntry.descriptionField"]
        XCTAssertTrue(descriptionField.exists)
        descriptionField.tap()
        descriptionField.typeText("test groceries")

        let contextPicker = app.segmentedControls["manualEntry.contextPicker"]
        XCTAssertTrue(contextPicker.exists)
        contextPicker.buttons["Work"].tap()

        let saveButton = app.buttons["manualEntry.saveButton"]
        XCTAssertTrue(saveButton.exists)
        XCTAssertTrue(saveButton.isEnabled, "Save must be enabled once a valid amount is entered")
        saveButton.tap()

        // The sheet only dismisses back to Log on a successful save — this
        // is the observable proof (from the UI-test process) that the
        // Transaction was created, with the Whisper model absent throughout.
        let personalButton = app.buttons["logView.personalButton"]
        XCTAssertTrue(personalButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.exists, "manual entry sheet should have dismissed after save")
    }

    func testSaveDisabledWithoutAmount() throws {
        let app = launchApp()

        let manualEntryButton = app.buttons["logView.manualEntryButton"]
        XCTAssertTrue(manualEntryButton.waitForExistence(timeout: 5))
        manualEntryButton.tap()

        let saveButton = app.buttons["manualEntry.saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled, "Save must stay disabled until a valid amount is entered")

        let cancelButton = app.buttons["manualEntry.cancelButton"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.tap()

        let personalButton = app.buttons["logView.personalButton"]
        XCTAssertTrue(personalButton.waitForExistence(timeout: 5))
    }
}
