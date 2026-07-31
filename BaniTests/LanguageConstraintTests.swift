import XCTest
@testable import Bani

/// A4 — the RO/EN language-decision logic (`LanguageConstraint`) and the
/// forced-language Setting (`TranscriptionLanguage`). Pure logic, so these run in
/// the gate (no Whisper model required). `WhisperService.transcribe` calls the
/// SAME `LanguageConstraint.resolve` / `choose`, so this is a test of the real
/// decision path. WhisperKit's `langProbs` are LOG-probabilities (higher = more
/// likely; argmax is valid).
final class LanguageConstraintTests: XCTestCase {

    // MARK: - Auto: constrained detection

    func testAutoPicksRomanianWhenRomanianIsHigher() {
        let probs: [String: Float] = ["ro": -0.20, "en": -1.50, "ru": -3.0]
        XCTAssertEqual(LanguageConstraint.choose(from: probs), "ro")
    }

    func testAutoPicksEnglishWhenEnglishIsHigher() {
        let probs: [String: Float] = ["ro": -2.00, "en": -0.30, "ru": -3.0]
        XCTAssertEqual(LanguageConstraint.choose(from: probs), "en")
    }

    /// The heart of the bug: even when a Slavic language is the raw argmax, the
    /// constraint never leaves {ro, en} — it picks the better of ro/en (here ro),
    /// so Romanian is never "transcribed" as Russian.
    func testAutoNeverLeavesRoEnEvenWhenRussianDominates() {
        let probs: [String: Float] = ["ru": -0.05, "ro": -0.40, "en": -2.10, "bg": -1.0]
        XCTAssertEqual(LanguageConstraint.choose(from: probs), "ro")
    }

    /// Neither ro nor en present (never expected — the map spans all languages)
    /// → floor to the primary language.
    func testAutoFloorsToPrimaryWhenNeitherPresent() {
        let probs: [String: Float] = ["ru": -0.1, "bg": -0.2]
        XCTAssertEqual(LanguageConstraint.choose(from: probs), "ro")
        XCTAssertEqual(LanguageConstraint.primary, "ro")
    }

    // MARK: - Setting respected (forced language reaches decode options)

    func testForcedRomanianSettingWinsOverDetector() {
        let probs: [String: Float] = ["en": -0.01, "ro": -5.0]   // detector says English
        XCTAssertEqual(LanguageConstraint.resolve(setting: .romanian, langProbs: probs), "ro")
    }

    func testForcedEnglishSettingWinsOverDetector() {
        let probs: [String: Float] = ["ro": -0.01, "en": -5.0]
        XCTAssertEqual(LanguageConstraint.resolve(setting: .english, langProbs: probs), "en")
    }

    func testAutoSettingDefersToConstrainedDetection() {
        let probs: [String: Float] = ["ro": -0.20, "en": -1.40]
        XCTAssertEqual(LanguageConstraint.resolve(setting: .auto, langProbs: probs), "ro")
    }

    func testForcedCodeMapping() {
        XCTAssertNil(TranscriptionLanguage.auto.forcedCode)
        XCTAssertEqual(TranscriptionLanguage.romanian.forcedCode, "ro")
        XCTAssertEqual(TranscriptionLanguage.english.forcedCode, "en")
    }
}
