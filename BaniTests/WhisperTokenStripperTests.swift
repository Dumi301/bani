import XCTest
@testable import Bani

/// A3 — the special-token strip: mixed decoder-token input becomes clean text,
/// Romanian diacritics (ș/ț/ă/î/â) survive, token-only input collapses to empty.
final class WhisperTokenStripperTests: XCTestCase {

    func testStripsLeadingDecoderTokens() {
        let dirty = "<|startoftranscript|><|ro|><|transcribe|> cincizeci de lei benzină"
        XCTAssertEqual(WhisperTokenStripper.strip(dirty), "cincizeci de lei benzină")
    }

    func testPreservesRomanianDiacritics() {
        let dirty = "<|ro|> șaptezeci și șase lei cumpărături în piață"
        let clean = WhisperTokenStripper.strip(dirty)
        XCTAssertEqual(clean, "șaptezeci și șase lei cumpărături în piață")
        for glyph in ["ș", "ț", "ă", "î"] {
            XCTAssertTrue(clean.contains(glyph), "diacritic \(glyph) must be preserved")
        }
    }

    func testStripsTimestampTokensAndCollapsesWhitespace() {
        let dirty = "<|0.00|>   cafea  <|2.50|>  la Starbucks"
        XCTAssertEqual(WhisperTokenStripper.strip(dirty), "cafea la Starbucks")
    }

    func testTokenOnlyInputBecomesEmpty() {
        XCTAssertEqual(WhisperTokenStripper.strip("<|startoftranscript|><|nospeech|>"), "")
    }

    func testCleanTextIsUnchanged() {
        XCTAssertEqual(WhisperTokenStripper.strip("benzină la OMV"), "benzină la OMV")
    }

    func testMalformedBracketFragmentsRemoved() {
        XCTAssertEqual(WhisperTokenStripper.strip("cafea <| la restaurant"), "cafea la restaurant")
    }

    func testContainsTokenDetection() {
        XCTAssertTrue(WhisperTokenStripper.containsToken("<|ro|> ceva"))
        XCTAssertTrue(WhisperTokenStripper.containsToken("ceva |>"))
        XCTAssertFalse(WhisperTokenStripper.containsToken("benzină la OMV"))
    }
}
