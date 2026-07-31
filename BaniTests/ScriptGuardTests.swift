import XCTest
@testable import Bani

/// A4 — the refiner-path script guard. A Cyrillic mistranscription is treated as
/// "no speech" (`hadContent == false`, routed to the existing error path);
/// genuine Romanian/English (Latin, incl. diacritics) is never flagged.
final class ScriptGuardTests: XCTestCase {

    func testCyrillicIsDominatedByNonLatin() {
        XCTAssertTrue(ScriptGuard.isDominatedByNonLatin("Привет как дела"))
    }

    func testRomanianWithDiacriticsIsLatin() {
        XCTAssertFalse(ScriptGuard.isDominatedByNonLatin("cazare mare cumpărături ăâîșț"))
    }

    func testEnglishIsLatin() {
        XCTAssertFalse(ScriptGuard.isDominatedByNonLatin("fifty lei groceries"))
    }

    /// No letters at all (digits + separators + currency) → not "dominated by
    /// non-Latin"; the amount survives.
    func testDigitsAndSeparatorsOnlyAreNotFlagged() {
        XCTAssertFalse(ScriptGuard.isDominatedByNonLatin("25.000 12,50 €"))
    }

    /// A4: a Cyrillic refined transcript → `hadContent` false (routes to the
    /// no-speech path); the text itself is preserved so it still shows in the
    /// "Last voice session" forensics row.
    func testApplyRejectsCyrillicRefinedTranscript() {
        let refined = RefinedTranscript(cleanText: "две тысячи рублей", hadContent: true)
        let guarded = ScriptGuard.apply(refined)
        XCTAssertFalse(guarded.hadContent)
        XCTAssertEqual(guarded.cleanText, "две тысячи рублей")
    }

    func testApplyKeepsLatinRefinedTranscript() {
        let refined = RefinedTranscript(cleanText: "cafea trei lei", hadContent: true)
        XCTAssertEqual(ScriptGuard.apply(refined), refined)
    }
}
