import Foundation
import SwiftData

/// The review side of auto-logged payments (Part A, card-contract compliance).
///
/// Auto-logged entries save immediately (they are real payments) but are never
/// invisible: the Log tab shows a "N auto-logged — review" chip listing the
/// UNREVIEWED ones. "Unreviewed" needs no new field on the frozen `Transaction`
/// — an auto-logged row is reviewed exactly when a `DecisionRecord` references it
/// (confirm/edit write one with its `transactionID`; discard writes one and
/// deletes the row). Each resolution feeds `TrustEngine` through `firedRuleID`,
/// identically to a voice confirmation card.
@MainActor
enum AutoLogReview {

    // MARK: - Reading

    /// Auto-logged transactions with no decision record yet — newest first.
    static func unreviewed(in context: ModelContext) -> [Transaction] {
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let autoLogged = all.filter { $0.source == .autoLogged }
        guard !autoLogged.isEmpty else { return [] }
        let reviewedIDs = Set(DecisionLedger.allRecords(in: context).compactMap { $0.transactionID })
        return autoLogged
            .filter { !reviewedIDs.contains($0.id) }
            .sorted { $0.date > $1.date }
    }

    static func unreviewedCount(in context: ModelContext) -> Int {
        unreviewed(in: context).count
    }

    // MARK: - Resolutions (each writes exactly one DecisionRecord)

    /// 👍 — the auto-log guess was right. Reinforces the fired category rule and
    /// records a confirmation (implicit-yes analogue for a payment that was correct).
    static func confirm(_ tx: Transaction, in context: ModelContext) {
        let firedRuleID = CategoryRuleStore.firedRuleID(description: tx.descriptionText, merchant: tx.merchant, in: context)
        if let match = CategoryRuleStore.bestMatch(description: tx.descriptionText, merchant: tx.merchant, in: context) {
            CategoryRuleStore.reinforce(keyword: match.keyword, origin: match.origin, in: context)
        }
        ContextRuleStore.record(finalContext: tx.context, description: tx.descriptionText, merchant: tx.merchant, in: context)
        DecisionLedger.record(
            outcome: .confirmedExplicit,
            transactionID: tx.id,
            guessedCategory: tx.category,
            guessedContext: tx.context,
            firedRuleID: firedRuleID,
            refinedText: tx.rawTranscript ?? "",
            in: context
        )
    }

    /// The editable fields of an auto-logged entry (mirrors the confirmation card).
    struct Edit: Equatable {
        var amount: Decimal
        var currency: Currency
        var descriptionText: String
        var categoryRef: CategoryRef?
        var context: TransactionContext
        var direction: TransactionDirection

        init(from tx: Transaction) {
            amount = tx.amount
            currency = tx.currency
            descriptionText = tx.descriptionText
            categoryRef = tx.categoryRef
            context = tx.context
            direction = tx.direction
        }
    }

    /// ✎ — apply an edit. Records `corrected` (+ which fields changed) or, when
    /// nothing changed, `confirmedExplicit`; learns a category correction and
    /// accrues the (corrected) context, exactly like the voice edit path.
    static func applyEdit(_ tx: Transaction, to edit: Edit, in context: ModelContext) {
        // Capture the ORIGINAL guess before mutating — the decision record scores
        // the guess the auto-log made, not the corrected value.
        let originalCategory = tx.category
        let originalContext = tx.context
        let originalRef = tx.categoryRef
        let firedRuleID = CategoryRuleStore.firedRuleID(description: tx.descriptionText, merchant: tx.merchant, in: context)
        let cleanDescription = edit.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: CorrectedFields = []
        if tx.amount != edit.amount { fields.insert(.amount) }
        if tx.currency != edit.currency { fields.insert(.currency) }
        if tx.descriptionText != cleanDescription { fields.insert(.description) }
        if originalRef != edit.categoryRef { fields.insert(.category) }
        if originalContext != edit.context { fields.insert(.context) }

        tx.amount = edit.amount
        tx.currency = edit.currency
        tx.descriptionText = cleanDescription
        tx.categoryRef = edit.categoryRef
        tx.context = edit.context
        tx.direction = edit.direction
        try? context.save()

        if fields.contains(.category), let ref = edit.categoryRef {
            CategoryRuleStore.learn(correctedRef: ref, description: cleanDescription, merchant: tx.merchant, in: context)
        }
        ContextRuleStore.record(finalContext: edit.context, description: cleanDescription, merchant: tx.merchant, in: context)

        DecisionLedger.record(
            outcome: fields.isEmpty ? .confirmedExplicit : .corrected,
            transactionID: tx.id,
            guessedCategory: originalCategory,
            guessedContext: originalContext,
            firedRuleID: firedRuleID,
            refinedText: tx.rawTranscript ?? "",
            correctedFields: fields,
            in: context
        )
    }

    /// A full snapshot of a discarded transaction so Undo can restore it verbatim.
    struct DiscardedSnapshot {
        let snapshot: Transaction
        let record: DecisionRecord
    }

    /// 🗑 — a real delete (likely a mis-fired automation), with a `discarded`
    /// decision record kept as a refiner-quality datapoint. Returns the material
    /// Undo needs (the deleted values + the record to remove on restore).
    @discardableResult
    static func discard(_ tx: Transaction, in context: ModelContext) -> DiscardedSnapshot {
        let firedRuleID = CategoryRuleStore.firedRuleID(description: tx.descriptionText, merchant: tx.merchant, in: context)
        let snapshot = Transaction(
            id: tx.id, amount: tx.amount, currency: tx.currency, context: tx.context,
            category: tx.category, customCategoryID: tx.customCategoryID,
            descriptionText: tx.descriptionText, merchant: tx.merchant, date: tx.date,
            rawTranscript: tx.rawTranscript, source: tx.source, direction: tx.direction,
            counterparty: tx.counterparty, attachmentID: tx.attachmentID,
            importBatchID: tx.importBatchID, createdAt: tx.createdAt
        )
        let record = DecisionLedger.record(
            outcome: .discarded,
            transactionID: nil,
            guessedCategory: tx.category,
            guessedContext: tx.context,
            firedRuleID: firedRuleID,
            refinedText: tx.rawTranscript ?? "",
            in: context
        )
        context.delete(tx)
        try? context.save()
        return DiscardedSnapshot(snapshot: snapshot, record: record)
    }

    /// Undo a discard: re-insert the transaction (same id → unreviewed again) and
    /// drop the discard record so trust data is not polluted by an undone action.
    static func restore(_ discarded: DiscardedSnapshot, in context: ModelContext) {
        context.insert(discarded.snapshot)
        context.delete(discarded.record)
        try? context.save()
    }
}
