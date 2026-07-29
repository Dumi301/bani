import XCTest
@testable import Bani

/// A3 — unit tests for the A2 segment quality gate, driven entirely by
/// synthetic segment metadata (no live audio, no WhisperKit). Covers keep,
/// drop-per-threshold, hallucination canaries, mixed, and all-dropped.
final class SegmentGateTests: XCTestCase {

    /// A clean, confident speech segment that passes every threshold.
    private func good(_ text: String) -> SpeechSegment {
        SpeechSegment(text: text, noSpeechProb: 0.05, avgLogprob: -0.25, compressionRatio: 1.4)
    }

    // MARK: - Keep

    func testGoodSegmentIsKept() {
        let outcome = SegmentGate.filter([good("cincizeci de lei benzină")])
        XCTAssertEqual(outcome.keptText, "cincizeci de lei benzină")
        XCTAssertEqual(outcome.keptCount, 1)
        XCTAssertEqual(outcome.droppedCount, 0)
        XCTAssertFalse(outcome.allDropped)
    }

    // MARK: - Drop per threshold

    func testHighNoSpeechProbIsDropped() {
        let s = SpeechSegment(text: "background music", noSpeechProb: 0.92, avgLogprob: -0.2, compressionRatio: 1.5)
        XCTAssertNotNil(SegmentGate.dropReason(s))
        XCTAssertEqual(SegmentGate.filter([s]).keptText, "")
    }

    func testLowAvgLogprobIsDropped() {
        let s = SpeechSegment(text: "mumble noise", noSpeechProb: 0.1, avgLogprob: -2.0, compressionRatio: 1.5)
        XCTAssertNotNil(SegmentGate.dropReason(s))
    }

    func testHighCompressionRatioIsDropped() {
        // Repetitive decode (a hallucination tell) — high gzip compression ratio.
        let s = SpeechSegment(text: "la la la la la", noSpeechProb: 0.1, avgLogprob: -0.3, compressionRatio: 3.6)
        XCTAssertNotNil(SegmentGate.dropReason(s))
    }

    func testBorderlineValuesAtThresholdAreKept() {
        // Exactly at each threshold must NOT drop (thresholds are strict >/<).
        let s = SpeechSegment(
            text: "chirie apartament",
            noSpeechProb: SegmentGate.maxNoSpeechProb,
            avgLogprob: SegmentGate.minAvgLogprob,
            compressionRatio: SegmentGate.maxCompressionRatio
        )
        XCTAssertNil(SegmentGate.dropReason(s))
    }

    // MARK: - Hallucination canaries

    func testKnownJunkPhraseCanaryIsDropped() {
        // Confident scores, but a classic Whisper-from-silence filler.
        let s = SpeechSegment(text: "Subtitrare de cineva", noSpeechProb: 0.05, avgLogprob: -0.1, compressionRatio: 1.2)
        XCTAssertTrue(SegmentGate.isHallucinationCanary(s.text))
        XCTAssertEqual(SegmentGate.filter([s]).keptText, "")
    }

    func testThanksForWatchingCanaryIsDropped() {
        XCTAssertTrue(SegmentGate.isHallucinationCanary("Thanks for watching!"))
    }

    func testRepeatedPunctuationCanaryIsDropped() {
        XCTAssertTrue(SegmentGate.isHallucinationCanary("......"))
        XCTAssertTrue(SegmentGate.isHallucinationCanary("!!!!"))
    }

    func testRealSpeechIsNotACanary() {
        XCTAssertFalse(SegmentGate.isHallucinationCanary("cincizeci de lei benzină"))
    }

    // MARK: - Mixed + all-dropped

    func testMixedKeepsOnlyGoodSegments() {
        let segments = [
            good("cincizeci de lei"),
            SpeechSegment(text: "music", noSpeechProb: 0.95, avgLogprob: -0.2, compressionRatio: 1.4),
            good("benzină"),
        ]
        let outcome = SegmentGate.filter(segments)
        XCTAssertEqual(outcome.keptText, "cincizeci de lei benzină")
        XCTAssertEqual(outcome.keptCount, 2)
        XCTAssertEqual(outcome.droppedCount, 1)
        XCTAssertFalse(outcome.allDropped)
    }

    func testAllDroppedProducesEmptyTextAndAllDroppedFlag() {
        let segments = [
            SpeechSegment(text: "♪♪♪", noSpeechProb: 0.99, avgLogprob: -3.0, compressionRatio: 5.0),
            SpeechSegment(text: "thanks for watching", noSpeechProb: 0.2, avgLogprob: -0.2, compressionRatio: 1.1),
        ]
        let outcome = SegmentGate.filter(segments)
        XCTAssertTrue(outcome.keptText.isEmpty)
        XCTAssertTrue(outcome.allDropped, "every segment dropped → route to the no-speech path")
    }

    func testEmptySegmentsAreNotAllDropped() {
        // No metadata at all is NOT the all-dropped case (the caller falls back
        // to raw text rather than forcing the no-speech path).
        let outcome = SegmentGate.filter([])
        XCTAssertTrue(outcome.keptText.isEmpty)
        XCTAssertFalse(outcome.allDropped)
        XCTAssertEqual(outcome.diagnostics, "no segment metadata")
    }
}
