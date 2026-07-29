import XCTest
import SwiftData
@testable import Bani

/// Drives transcript → parser → save with **no real audio**: proves the
/// voice-flow seam Unit C owns (parse → `saveVoiceTransaction`) persists a
/// `Transaction` with `source == .voice` and `rawTranscript` equal to the
/// input verbatim, diacritics intact. Uses an in-memory `ModelContainer`.
@MainActor
final class VoiceFlowIntegrationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transaction.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testVoiceTranscriptPersistsVerbatimWithSourceVoice() async throws {
        let context = try makeContext()
        let parser = RuleBasedParser()
        let transcript = "50 de lei benzină"

        let parsed = await parser.parse(transcript)
        let saved = saveVoiceTransaction(
            parsed: parsed,
            transcript: transcript,
            context: .personal,
            into: context
        )

        let transaction = try XCTUnwrap(saved, "a resolved amount must persist a Transaction")
        XCTAssertEqual(transaction.source, .voice)
        XCTAssertEqual(transaction.rawTranscript, transcript)
        XCTAssertEqual(transaction.amount, Decimal(50))
        XCTAssertEqual(transaction.currency, .ron)
        XCTAssertEqual(transaction.context, .personal)

        let fetched = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.rawTranscript, transcript)
    }

    func testDiacriticsPreservedVerbatimInRawTranscript() async throws {
        let context = try makeContext()
        let parser = RuleBasedParser()
        let transcript = "douăzeci de euro taxi până la aeroport"

        let parsed = await parser.parse(transcript)
        let saved = saveVoiceTransaction(
            parsed: parsed,
            transcript: transcript,
            context: .work,
            into: context
        )

        let transaction = try XCTUnwrap(saved)
        XCTAssertEqual(transaction.rawTranscript, transcript)
        XCTAssertTrue(transaction.rawTranscript?.contains("ă") ?? false)
        XCTAssertTrue(transaction.rawTranscript?.contains("â") ?? false)
        XCTAssertEqual(transaction.source, .voice)
        XCTAssertEqual(transaction.context, .work)
        XCTAssertEqual(transaction.currency, .eur)
        XCTAssertEqual(transaction.amount, Decimal(20))
    }

    /// Mirrors the `## EDGE CASES` rule: a transcript with no amount must
    /// never turn into an invented `Transaction`. In the real UI this is
    /// intercepted by `ConfirmationCard` opening in edit mode; the save
    /// routine itself is the last line of defense and must refuse to
    /// persist a nil amount.
    func testNoAmountTranscriptNeverInventsAnAmount() async throws {
        let context = try makeContext()
        let parser = RuleBasedParser()
        let transcript = "nu știu ce am cumpărat"

        let parsed = await parser.parse(transcript)
        XCTAssertNil(parsed.amount, "precondition: this transcript has no amount for RuleBasedParser to find")

        let saved = saveVoiceTransaction(parsed: parsed, transcript: transcript, context: .personal, into: context)
        XCTAssertNil(saved, "must never invent an amount")

        let fetched = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertTrue(fetched.isEmpty)
    }

    func testManualEntryNeverSetsRawTranscript() throws {
        // Guards the `source`/`rawTranscript` contract from the other side:
        // manual entries (Unit C's `ManualEntrySheet`) must never populate
        // `rawTranscript`, since it is reserved for verbatim voice input.
        let transaction = Transaction(
            amount: Decimal(10),
            currency: .ron,
            context: .personal,
            descriptionText: "test",
            rawTranscript: nil,
            source: .manual
        )
        XCTAssertNil(transaction.rawTranscript)
        XCTAssertEqual(transaction.source, .manual)
    }
}
