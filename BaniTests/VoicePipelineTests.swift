import XCTest
@testable import Bani

/// Unit tests for the three A2 contracts, asserting the **card-state outcome**
/// each pipeline result produces. Both `runVoicePipeline` and
/// `ConfirmationCard.init` funnel through `VoicePipelineResult.opensInEditMode`,
/// so asserting it here is asserting the card's opening state directly — no UI
/// harness needed.
@MainActor
final class VoicePipelineTests: XCTestCase {

    private enum StubTranscribeError: LocalizedError {
        case boom
        var errorDescription: String? { "stub transcription failure" }
    }

    private let dummyURL = URL(fileURLWithPath: "/dev/null/does-not-matter.wav")

    private func parseWithRuleParser(_ text: String) async -> ParsedTransaction {
        await RuleBasedParser().parse(text)
    }

    // MARK: - A2 contract 1 — transcribe() throws → edit mode + error, no amount

    func testThrowingTranscriberOpensEditModeWithError() async {
        let result = await runVoicePipeline(
            audioFileURL: dummyURL,
            transcribe: { _ in throw StubTranscribeError.boom },
            parse: { await self.parseWithRuleParser($0) }
        )

        XCTAssertNil(result.parsed.amount, "a thrown transcribe must never invent an amount")
        XCTAssertTrue(result.signalsError, "the card must surface the transcription error")
        XCTAssertEqual(result.errorMessage, "stub transcription failure", "raw error message must be accessible")
        XCTAssertTrue(result.opensInEditMode, "the card stays open in edit mode")
        // The card init derives the same opening state.
        XCTAssertTrue(VoicePipelineResult.shouldOpenInEditMode(parsedAmount: result.parsed.amount, errorMessage: result.errorMessage))
    }

    // MARK: - A2 contract 1 (empty variant) — empty/whitespace transcript → edit mode + error

    func testEmptyTranscriptOpensEditModeWithError() async {
        let result = await runVoicePipeline(
            audioFileURL: dummyURL,
            transcribe: { _ in "   \n  " },
            parse: { await self.parseWithRuleParser($0) }
        )

        XCTAssertNil(result.parsed.amount, "empty transcript must never invent an amount")
        XCTAssertTrue(result.signalsError)
        XCTAssertEqual(result.errorMessage, VoicePipelineResult.emptyTranscriptMessage)
        XCTAssertTrue(result.opensInEditMode)
    }

    // MARK: - A2 contract 2 — non-empty transcript, no amount → edit mode, transcript kept, NO error

    func testNilAmountTranscriptOpensEditModeWithTranscriptAndNoError() async {
        let transcript = "nu știu ce am cumpărat"
        let result = await runVoicePipeline(
            audioFileURL: dummyURL,
            transcribe: { _ in transcript },
            parse: { await self.parseWithRuleParser($0) }
        )

        XCTAssertNil(result.parsed.amount, "precondition: this transcript has no amount")
        XCTAssertFalse(result.signalsError, "a nil-amount parse is NOT a transcription failure")
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.transcript, transcript, "raw transcript must stay visible for editing")
        XCTAssertTrue(result.opensInEditMode, "no amount → card opens in edit mode, not the auto-save summary")
    }

    // MARK: - Positive control — amount present → summary (auto-save) mode, no error

    func testResolvedAmountOpensSummaryMode() async {
        let result = await runVoicePipeline(
            audioFileURL: dummyURL,
            transcribe: { _ in "50 lei benzină" },
            parse: { await self.parseWithRuleParser($0) }
        )

        XCTAssertEqual(result.parsed.amount, Decimal(50))
        XCTAssertEqual(result.parsed.currency, .ron)
        XCTAssertNil(result.errorMessage)
        XCTAssertFalse(result.opensInEditMode, "a resolved amount opens the summary/countdown, not edit mode")
    }
}
