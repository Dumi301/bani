import XCTest
@testable import Bani

/// B4 — unit tests for the confirmation card's pure seams: the configurable
/// auto-save delay (default 4 s, clamped 2–8) and the countdown-pause predicate,
/// plus the guarantee that the category chip is ALWAYS filled (never nil).
final class ConfirmationCardTests: XCTestCase {

    // MARK: - Configurable auto-save delay

    func testDefaultDelayIsFourSeconds() {
        // The pacing change: was 2 s, now 4 s.
        XCTAssertEqual(ConfirmationCard.defaultAutoSaveDelay, 4.0)
    }

    func testUnsetOrZeroStoredDurationFallsBackToDefault() {
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(0), 4.0)
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(-3), 4.0)
    }

    func testStoredDurationIsClampedToTwoThroughEight() {
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(1), 2.0, "below the floor clamps up to 2")
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(2), 2.0)
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(5), 5.0)
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(8), 8.0)
        XCTAssertEqual(ConfirmationCard.resolvedAutoSaveDelay(12), 8.0, "above the ceiling clamps down to 8")
    }

    func testSettingsRangeMatchesTheClamp() {
        XCTAssertEqual(ConfirmationCard.minAutoSaveDelay, 2.0)
        XCTAssertEqual(ConfirmationCard.maxAutoSaveDelay, 8.0)
    }

    // MARK: - Countdown pauses on any interaction

    func testCountdownRunsOnlyWhenFullyIdle() {
        XCTAssertTrue(ConfirmationCard.shouldRunCountdown(
            isEditing: false, isPickingCategory: false, isPausedByBackground: false, isTouching: false))
    }

    func testEditingPausesCountdown() {
        XCTAssertFalse(ConfirmationCard.shouldRunCountdown(
            isEditing: true, isPickingCategory: false, isPausedByBackground: false, isTouching: false))
    }

    func testPickingCategoryPausesCountdown() {
        XCTAssertFalse(ConfirmationCard.shouldRunCountdown(
            isEditing: false, isPickingCategory: true, isPausedByBackground: false, isTouching: false))
    }

    func testBackgroundingPausesCountdown() {
        XCTAssertFalse(ConfirmationCard.shouldRunCountdown(
            isEditing: false, isPickingCategory: false, isPausedByBackground: true, isTouching: false))
    }

    func testTouchAnywherePausesCountdown() {
        XCTAssertFalse(ConfirmationCard.shouldRunCountdown(
            isEditing: false, isPickingCategory: false, isPausedByBackground: false, isTouching: true))
    }

    // MARK: - Chip is always present (Q2 — never blank)

    func testCategoryGuessIsNeverNilSoChipIsAlwaysFilled() {
        // No rules at all, empty text — the guess is still a real category.
        XCTAssertEqual(Categorizer.category(for: "", rules: []), .other)
        XCTAssertEqual(Categorizer.category(for: "anything unmatched", rules: []), .other)
    }
}
