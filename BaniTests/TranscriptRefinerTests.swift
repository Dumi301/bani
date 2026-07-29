import XCTest
@testable import Bani

/// A3 — the deterministic `RuleBasedRefiner` (the CI-exercised refinement path)
/// plus its wiring into `runVoicePipeline`. Asserts the five A1 guarantees:
/// non-speech artifacts (RO + EN) are stripped, pause fragments merge, amounts
/// survive verbatim, diacritics survive, and an all-artifact recording resolves
/// to `hadContent == false` (the no-speech path, never a blank card).
@MainActor
final class TranscriptRefinerTests: XCTestCase {

    private func refine(_ raw: String) -> RefinedTranscript {
        RuleBasedRefiner.refineSync(raw)
    }

    // MARK: - Artifact stripping (RO + EN)

    func testStripsEnglishNonSpeechArtifacts() {
        XCTAssertFalse(refine("[music]").hadContent)
        XCTAssertFalse(refine("[blank audio]").hadContent)
        XCTAssertFalse(refine("[BLANK_AUDIO]").hadContent)
        XCTAssertFalse(refine("(background noise)").hadContent)
        XCTAssertFalse(refine("(applause)").hadContent)
    }

    func testStripsRomanianNonSpeechArtifacts() {
        XCTAssertFalse(refine("(muzică)").hadContent)
        XCTAssertFalse(refine("[muzică]").hadContent)
        XCTAssertFalse(refine("(zgomot de fundal)").hadContent)
    }

    func testStripsArtifactsButKeepsRealSpeechAroundThem() {
        let result = refine("[music] 20 lei benzină [blank audio]")
        XCTAssertTrue(result.hadContent)
        XCTAssertEqual(result.cleanText, "20 lei benzină")
    }

    func testStripsInlineRomanianArtifactMidSentence() {
        let result = refine("taxi (muzică) 30 lei")
        XCTAssertTrue(result.hadContent)
        XCTAssertEqual(result.cleanText, "taxi 30 lei")
    }

    // MARK: - Fragment merge

    func testMergesPauseFragments() {
        // The brief's canonical example.
        XCTAssertEqual(refine("cazare. mare.").cleanText, "cazare mare")
    }

    func testMergesMultipleFragmentsAndOtherPunctuation() {
        XCTAssertEqual(refine("cafea, la birou; da!").cleanText, "cafea la birou da")
    }

    func testCollapsesDictationStutterButNeverNumbers() {
        XCTAssertEqual(refine("taxi taxi 20 lei").cleanText, "taxi 20 lei")
        // A repeated NUMBER is kept verbatim — never fold a number.
        XCTAssertEqual(refine("20 20 lei").cleanText, "20 20 lei")
    }

    // MARK: - Amounts survive verbatim

    func testDecimalAmountSurvivesVerbatim() {
        let result = refine("12,50 lei cafea")
        XCTAssertTrue(result.cleanText.contains("12,50"), "decimal separator must be preserved: \(result.cleanText)")
    }

    func testDotDecimalAmountSurvivesVerbatim() {
        let result = refine("am dat 12.50 pe cafea.")
        XCTAssertTrue(result.cleanText.contains("12.50"), "dot decimal must be preserved: \(result.cleanText)")
    }

    func testIntegerAmountSurvivesFragmentMerge() {
        let result = refine("50 de lei. benzină.")
        XCTAssertTrue(result.cleanText.contains("50"))
        XCTAssertEqual(result.cleanText, "50 de lei benzină")
    }

    // MARK: - Diacritics survive

    func testDiacriticsSurviveRefinement() {
        let result = refine("mâncare. bună.")
        XCTAssertEqual(result.cleanText, "mâncare bună")
        XCTAssertTrue(result.cleanText.contains("â"))
        XCTAssertTrue(result.cleanText.contains("ă"))
    }

    func testDiacriticsSurviveWithArtifactAndAmount() {
        let result = refine("[music] cincizeci de lei benzină și țigări")
        XCTAssertTrue(result.hadContent)
        XCTAssertTrue(result.cleanText.contains("ă"))
        XCTAssertTrue(result.cleanText.contains("ț"))
        XCTAssertFalse(result.cleanText.contains("music"))
    }

    // MARK: - All-artifact → hadContent false

    func testAllArtifactResolvesToNoContent() {
        XCTAssertFalse(refine("   [music]   ").hadContent)
        XCTAssertFalse(refine("[music] (muzică) [blank audio]").hadContent)
        XCTAssertFalse(refine("...").hadContent, "pure punctuation is not content")
        XCTAssertTrue(refine("   [music]   ").cleanText.isEmpty)
    }

    // MARK: - Pipeline wiring (Whisper → refine → parse)

    func testPipelineRefinesBeforeParsingAndKeepsRawVerbatim() async {
        let raw = "[music] 30 lei taxi"
        let result = await runVoicePipeline(
            audioFileURL: URL(fileURLWithPath: "/dev/null/x.wav"),
            transcribe: { _ in raw },
            parse: { await RuleBasedParser().parse($0) }
        )
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.transcript, raw, "rawTranscript stays the TRUE raw output")
        XCTAssertEqual(result.cleanText, "30 lei taxi", "the parser sees the refined text")
        XCTAssertEqual(result.parsed.amount, Decimal(30), "the amount parses from the cleaned text")
    }

    func testPipelineDecimalSurvivesRefineAndParse() async {
        let result = await runVoicePipeline(
            audioFileURL: URL(fileURLWithPath: "/dev/null/x.wav"),
            transcribe: { _ in "12,50 lei cafea." },
            parse: { await RuleBasedParser().parse($0) }
        )
        XCTAssertEqual(result.parsed.amount, Decimal(string: "12.50"))
    }

    func testPipelineAllArtifactRecordingHitsNoSpeechPath() async {
        let raw = "[blank audio]"
        let result = await runVoicePipeline(
            audioFileURL: URL(fileURLWithPath: "/dev/null/x.wav"),
            transcribe: { _ in raw },
            parse: { await RuleBasedParser().parse($0) }
        )
        XCTAssertEqual(result.errorMessage, VoicePipelineResult.emptyTranscriptMessage,
                       "an all-artifact recording routes to the no-speech error path")
        XCTAssertNil(result.parsed.amount, "never invent an amount from noise")
        XCTAssertEqual(result.transcript, raw, "the raw noise is still kept for on-device diagnostics")
    }
}
