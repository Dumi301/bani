import XCTest
import SwiftData
@testable import Bani

/// B6 — the SwiftData-backed feedback seams: one record per resolution, outcome
/// counts, per-rule trust samples (incl. trusted-undo → miss), context-rule
/// promotion end to end, and CorrectionMemory round-trip + LRU cap.
@MainActor
final class FeedbackLedgerTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transaction.self, CategoryRule.self,
            DecisionRecord.self, ContextRule.self, CorrectionMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - One record per resolution

    func testEachResolutionWritesExactlyOneRecord() throws {
        let context = try makeContext()
        DecisionLedger.record(outcome: .confirmedExplicit, guessedCategory: .fuel, guessedContext: .personal, in: context)
        DecisionLedger.record(outcome: .confirmedImplicit, guessedCategory: .fuel, guessedContext: .personal, in: context)
        DecisionLedger.record(outcome: .corrected, guessedCategory: .fuel, guessedContext: .personal, in: context)
        DecisionLedger.record(outcome: .discarded, guessedCategory: .fuel, guessedContext: .personal, in: context)

        let all = try context.fetch(FetchDescriptor<DecisionRecord>())
        XCTAssertEqual(all.count, 4, "each of the four resolution paths writes exactly one record")
    }

    func testCountsAggregateByOutcome() throws {
        let context = try makeContext()
        DecisionLedger.record(outcome: .confirmedExplicit, guessedCategory: nil, guessedContext: .personal, in: context)
        DecisionLedger.record(outcome: .confirmedImplicit, guessedCategory: nil, guessedContext: .personal, in: context)
        DecisionLedger.record(outcome: .corrected, guessedCategory: nil, guessedContext: .personal, in: context)
        DecisionLedger.record(outcome: .discarded, guessedCategory: nil, guessedContext: .personal, in: context)

        let counts = DecisionLedger.counts(in: context)
        XCTAssertEqual(counts.asked, 4)
        XCTAssertEqual(counts.confirmed, 2)
        XCTAssertEqual(counts.corrected, 1)
        XCTAssertEqual(counts.discarded, 1)
    }

    // MARK: - Trust samples

    func testSamplesMapOutcomesAndExcludeDiscarded() throws {
        let context = try makeContext()
        let ruleID = UUID()
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Chronological, distinct timestamps so the sort is stable.
        context.insert(DecisionRecord(createdAt: base.addingTimeInterval(1), guessedCategory: .fuel, guessedContext: .personal, firedRuleID: ruleID, outcome: .confirmedExplicit))
        context.insert(DecisionRecord(createdAt: base.addingTimeInterval(2), guessedCategory: .fuel, guessedContext: .personal, firedRuleID: ruleID, outcome: .corrected))
        context.insert(DecisionRecord(createdAt: base.addingTimeInterval(3), guessedCategory: .fuel, guessedContext: .personal, firedRuleID: ruleID, outcome: .discarded))
        context.insert(DecisionRecord(createdAt: base.addingTimeInterval(4), guessedCategory: .fuel, guessedContext: .personal, firedRuleID: ruleID, outcome: .confirmedImplicit))
        // A different rule's record must not leak into these samples.
        context.insert(DecisionRecord(createdAt: base.addingTimeInterval(5), guessedCategory: .dining, guessedContext: .personal, firedRuleID: UUID(), outcome: .corrected))
        try context.save()

        XCTAssertEqual(DecisionLedger.samples(forRuleID: ruleID, in: context), [true, false, true],
                       "confirmations → true, corrected → false, discarded excluded, chronological")
    }

    func testTrustedSaveUndoCountsAsMiss() throws {
        let context = try makeContext()
        let ruleID = UUID()
        let record = DecisionLedger.record(
            outcome: .confirmedImplicit,
            guessedCategory: .fuel,
            guessedContext: .personal,
            firedRuleID: ruleID,
            in: context
        )
        XCTAssertEqual(DecisionLedger.samples(forRuleID: ruleID, in: context), [true])

        DecisionLedger.markTrustedSaveUndone(record, in: context)
        XCTAssertEqual(DecisionLedger.samples(forRuleID: ruleID, in: context), [false],
                       "undoing a trusted save flips its record to a miss")
    }

    // MARK: - DecisionRecord field round-trip

    func testCorrectedFieldsAndOutcomeRoundTripThroughSwiftData() throws {
        let context = try makeContext()
        DecisionLedger.record(
            outcome: .corrected,
            guessedCategory: .groceries,
            guessedContext: .work,
            firedRuleID: UUID(),
            correctedFields: [.amount, .category, .date],
            in: context
        )
        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<DecisionRecord>()).first)
        XCTAssertEqual(fetched.outcome, .corrected)
        XCTAssertTrue(fetched.correctedFields.contains(.amount))
        XCTAssertTrue(fetched.correctedFields.contains(.category))
        XCTAssertTrue(fetched.correctedFields.contains(.date))
        XCTAssertFalse(fetched.correctedFields.contains(.currency))
        XCTAssertFalse(fetched.correctedFields.contains(.context))
    }

    // MARK: - Context rule promotion (end to end)

    func testContextRulePromotesAfterThreeConsistentSaves() throws {
        let context = try makeContext()
        // Three work saves of "taxi aeroport" → the salient keyword "aeroport"
        // pre-selects Work.
        for _ in 0..<3 {
            ContextRuleStore.record(finalContext: .work, description: "taxi aeroport", in: context)
        }
        XCTAssertEqual(ContextRuleStore.preselectedContext(description: "aeroport", in: context), .work)

        // A single Personal save drags the ratio to 3/4 = 0.75 → no pre-selection.
        ContextRuleStore.record(finalContext: .personal, description: "aeroport", in: context)
        XCTAssertNil(ContextRuleStore.preselectedContext(description: "aeroport", in: context))
    }

    func testContextRuleUnknownKeywordHasNoPreselection() throws {
        let context = try makeContext()
        XCTAssertNil(ContextRuleStore.preselectedContext(description: "cafea", in: context))
    }

    // MARK: - CorrectionMemory round-trip + LRU cap

    func testCorrectionMemoryRoundTripIsNormalizedAndUpsert() throws {
        let context = try makeContext()
        CorrectionMemoryStore.remember(rawTranscript: "cazare mare", correctedDescription: "hotel booking", in: context)

        // Normalized-equal (case + diacritics folded) lookup hits.
        XCTAssertEqual(CorrectionMemoryStore.lookup(rawTranscript: "Cazare Mare", in: context), "hotel booking")
        XCTAssertNil(CorrectionMemoryStore.lookup(rawTranscript: "altceva", in: context))

        // Re-remembering the same key updates in place (no duplicate row).
        CorrectionMemoryStore.remember(rawTranscript: "cazare mare", correctedDescription: "hotel Marea Neagră", in: context)
        XCTAssertEqual(CorrectionMemoryStore.lookup(rawTranscript: "cazare mare", in: context), "hotel Marea Neagră")
        XCTAssertEqual(CorrectionMemoryStore.count(in: context), 1)
    }

    func testCorrectionMemoryEnforcesLruCap() throws {
        let context = try makeContext()
        let cap = CorrectionMemoryStore.cap
        for index in 0..<cap {
            CorrectionMemoryStore.remember(rawTranscript: "transcript number \(index)", correctedDescription: "desc \(index)", in: context)
        }
        XCTAssertEqual(CorrectionMemoryStore.count(in: context), cap)

        // One past the cap: size stays capped, and the just-added entry survives.
        CorrectionMemoryStore.remember(rawTranscript: "transcript number \(cap)", correctedDescription: "desc \(cap)", in: context)
        XCTAssertEqual(CorrectionMemoryStore.count(in: context), cap, "the store never exceeds its cap")
        XCTAssertEqual(CorrectionMemoryStore.lookup(rawTranscript: "transcript number \(cap)", in: context), "desc \(cap)",
                       "the most-recent entry is retained")
    }
}
