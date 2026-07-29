import Foundation
import SwiftData

/// The SwiftData-backed side of the feedback ledger (B1). Writes exactly one
/// `DecisionRecord` per card resolution and reads the ledger back for the trust
/// engine (B4) and diagnostics (B5). The pure trust math lives in `TrustEngine`;
/// this type only bridges it to a `ModelContext`, mirroring `CategoryRuleStore`.
@MainActor
enum DecisionLedger {

    // MARK: - Writing (one record per resolution)

    @discardableResult
    static func record(
        outcome: DecisionOutcome,
        transactionID: UUID? = nil,
        guessedCategory: TransactionCategory?,
        guessedContext: TransactionContext,
        firedRuleID: UUID? = nil,
        refinedText: String = "",
        correctedFields: CorrectedFields = [],
        latencySeconds: Double = 0,
        in context: ModelContext
    ) -> DecisionRecord {
        let record = DecisionRecord(
            transactionID: transactionID,
            guessedCategory: guessedCategory,
            guessedContext: guessedContext,
            firedRuleID: firedRuleID,
            refinedText: refinedText,
            outcome: outcome,
            correctedFields: correctedFields,
            latencySeconds: latencySeconds
        )
        context.insert(record)
        try? context.save()
        return record
    }

    /// B4: a trusted-flow auto-save that the user undoes becomes a miss. Rewrites
    /// the SAME record (still exactly one per resolution) rather than adding a new
    /// one, so the trust window sees a miss where a confirmation used to be.
    static func markTrustedSaveUndone(_ record: DecisionRecord, in context: ModelContext) {
        record.outcome = .corrected
        record.transactionID = nil
        try? context.save()
    }

    // MARK: - Reading

    static func allRecords(in context: ModelContext) -> [DecisionRecord] {
        let descriptor = FetchDescriptor<DecisionRecord>(sortBy: [SortDescriptor(\DecisionRecord.createdAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Chronological hit/miss samples for one fired rule — the input to
    /// `TrustEngine`. `discarded` outcomes are excluded (not a category signal).
    static func samples(forRuleID ruleID: UUID, in context: ModelContext) -> [Bool] {
        allRecords(in: context)
            .filter { $0.firedRuleID == ruleID }
            .compactMap { $0.outcome.trustSample }
    }

    /// Whether the rule that fired is TRUSTED right now (B4) — the card auto-saves
    /// instead of asking. `nil` rule (no match, guess was `.other`) is never trusted.
    static func isTrusted(ruleID: UUID?, in context: ModelContext) -> Bool {
        guard let ruleID else { return false }
        return TrustEngine.isTrusted(samples(forRuleID: ruleID, in: context))
    }

    // MARK: - Diagnostics (B5)

    struct Counts: Equatable, Sendable {
        var asked = 0
        var confirmed = 0
        var corrected = 0
        var discarded = 0
    }

    static func counts(in context: ModelContext) -> Counts {
        var counts = Counts()
        for record in allRecords(in: context) {
            counts.asked += 1
            switch record.outcome {
            case .confirmedExplicit, .confirmedImplicit: counts.confirmed += 1
            case .corrected: counts.corrected += 1
            case .discarded: counts.discarded += 1
            }
        }
        return counts
    }
}
