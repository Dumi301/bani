import Foundation
import SwiftData

/// Cross-source duplicate detection (P8). The write side runs at save time for
/// every entry surface — voice, manual, share-capture, auto-log, and (batch-level)
/// import — and NEVER blocks or refuses a save (the never-drop law): it only
/// flags a possible collision (`Transaction.duplicateOfID`) for a human to
/// resolve later. Deliberately NOT `@MainActor` on the detection side — mirrors
/// `PresetSeeding` / `ImportFingerprint` / `AttachmentStore`: it is called from
/// BOTH `@MainActor` UI save paths (`ConfirmationCard`, `ManualEntrySheet`,
/// `ShareCaptureCard`, `AutoLogWriter`) and the background `@ModelActor
/// ImportCommitRunner`, so it must run correctly in whichever isolation domain
/// calls it. The resolution side (merge / keep-both) writes a `DecisionRecord`
/// via the `@MainActor`-isolated `DecisionLedger`, so those two functions are
/// `@MainActor` — reached only from the review surface, which is always on-screen.
enum DedupService {

    /// The candidate-fetch window: broader than the ±1 day fingerprint tier so a
    /// date/timezone edge case near a calendar-day boundary is never excluded
    /// BEFORE `TransactionFingerprint` gets to narrow it to exact/probable/none.
    static let candidateWindow: TimeInterval = 3 * 24 * 60 * 60

    // MARK: - Detection (safe from any actor — no DecisionRecord write)

    /// Whether `transaction` is itself EXCLUDED from ever being a dedup
    /// candidate — reconciliation adjustments (P4's category) and loan
    /// principal/interest slices (`loanID != nil`) are never dedup candidates
    /// on EITHER side (never flagged themselves, never offered as a match for
    /// something else).
    static func isExcluded(_ transaction: Transaction) -> Bool {
        transaction.loanID != nil || transaction.customCategoryID == ReconciliationCategories.adjustmentCategoryID
    }

    /// The candidate pool for `key`: every transaction in `pool` within the
    /// ±3-day / same-amount / same-currency window, excluding `excludingID`
    /// (the transaction being checked) and every excluded row (loan slice /
    /// reconciliation adjustment) on the candidate side. In-memory filter — the
    /// house style (no enum `#Predicate`).
    static func candidates(for key: TransactionFingerprint.Key, excludingID: UUID?, in pool: [Transaction]) -> [Transaction] {
        pool.filter { candidate in
            guard candidate.id != excludingID else { return false }
            guard !isExcluded(candidate) else { return false }
            guard candidate.amount == key.amount, candidate.currency == key.currency else { return false }
            return abs(candidate.date.timeIntervalSince(key.date)) <= candidateWindow
        }
    }

    /// The best cross-source match for `key`/`origin` among `pool` — the
    /// highest-confidence, DIFFERENT-ORIGIN hit (same-origin pairs are NEVER
    /// flagged — legit duplicate hand-entered/voice spend is expected; see
    /// `DedupOrigin` for why this is origin, not the raw `TransactionSource`),
    /// or `nil`. `exact` beats `probable`; ties keep the first encountered
    /// (deterministic given a stable fetch order).
    static func bestMatch(
        for key: TransactionFingerprint.Key,
        origin: DedupOrigin,
        excludingID: UUID?,
        candidates pool: [Transaction]
    ) -> (transaction: Transaction, confidence: DedupConfidence)? {
        let scoped = candidates(for: key, excludingID: excludingID, in: pool)
        var best: (Transaction, DedupConfidence)?
        for candidate in scoped {
            let candidateOrigin = DedupOrigin.of(source: candidate.source, rawTranscript: candidate.rawTranscript)
            guard candidateOrigin != origin else { continue }
            let candidateKey = TransactionFingerprint.key(for: candidate)
            let confidence = TransactionFingerprint.confidence(key, candidateKey)
            guard confidence != .none else { continue }
            if best == nil || confidence.rank > best!.1.rank {
                best = (candidate, confidence)
            }
        }
        return best
    }

    /// Flag a just-saved transaction against the rest of the store: sets
    /// `duplicateOfID` when a cross-source exact/probable match exists. Fetches
    /// once, filters in memory. Never removes or refuses anything, never
    /// touched for an excluded row (loan slice / reconciliation adjustment —
    /// those never call this at all, but the guard is defensive too). Safe to
    /// call from ANY actor — see the type doc.
    @discardableResult
    static func flagIfDuplicate(_ transaction: Transaction, in context: ModelContext) -> Transaction? {
        guard !isExcluded(transaction) else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let key = TransactionFingerprint.key(for: transaction)
        let origin = DedupOrigin.of(source: transaction.source, rawTranscript: transaction.rawTranscript)
        guard let match = bestMatch(for: key, origin: origin, excludingID: transaction.id, candidates: all) else {
            return nil
        }
        transaction.duplicateOfID = match.transaction.id
        try? context.save()
        return match.transaction
    }

    /// The batch-level import path (P8 build item 4): checks `key`/`.imported`
    /// against an ALREADY-FETCHED pool of existing store rows (so a whole import
    /// batch fetches the store once, not once per row) and returns the match's
    /// id when found. `ImportCommitRunner` sets `duplicateOfID` on the newly
    /// inserted row itself — no separate write here, no modal, no row-by-row
    /// prompt; the flag is discoverable later in the same review surface.
    static func batchMatch(
        for key: TransactionFingerprint.Key,
        excludingID: UUID?,
        existing pool: [Transaction]
    ) -> UUID? {
        bestMatch(for: key, origin: .imported, excludingID: excludingID, candidates: pool)?.transaction.id
    }

    // MARK: - Resolution (review surface — @MainActor, writes a DecisionRecord)

    /// Every currently-flagged, unresolved possible duplicate — newest first.
    /// "Unresolved" = `duplicateOfID` still set (both `keepBoth` and `merge`
    /// clear it).
    @MainActor
    static func flagged(in context: ModelContext) -> [Transaction] {
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.filter { $0.duplicateOfID != nil }.sorted { $0.date > $1.date }
    }

    @MainActor
    static func flaggedCount(in context: ModelContext) -> Int {
        flagged(in: context).count
    }

    /// The transaction `tx` is flagged as a possible duplicate of, or `nil` if
    /// the pointed-at row is already gone.
    @MainActor
    static func matchedTransaction(for tx: Transaction, in context: ModelContext) -> Transaction? {
        guard let otherID = tx.duplicateOfID else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.first { $0.id == otherID }
    }

    /// "Keep both" — the flagged pair are legitimately separate payments;
    /// clears the flag (no data changes) and records the review as a plain
    /// confirmation, the same scoring AutoLogReview gives a reviewed-and-accepted
    /// item.
    @MainActor
    static func keepBoth(_ transaction: Transaction, in context: ModelContext) {
        guard transaction.duplicateOfID != nil else { return }
        transaction.duplicateOfID = nil
        try? context.save()
        DecisionLedger.record(
            outcome: .confirmedExplicit,
            transactionID: transaction.id,
            guessedCategory: transaction.category,
            guessedContext: transaction.context,
            in: context
        )
    }

    /// "Merge" — the flagged pair are the same real payment. Keeps the RICHER
    /// record: the earlier-created transaction wins its id (a stable identity
    /// anything else may already reference), unions in whatever the other side
    /// carries that the keeper lacks (attachment, project, loan, counterparty,
    /// merchant, raw transcript), deletes the loser, and writes exactly one
    /// `.corrected` `DecisionRecord` with `.merge` set. Returns the kept
    /// transaction, or `nil` when the pointed-at row is already gone (the stale
    /// flag is cleared rather than left unresolvable).
    @MainActor
    @discardableResult
    static func merge(_ transaction: Transaction, in context: ModelContext) -> Transaction? {
        guard let duplicateOfID = transaction.duplicateOfID else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        guard let other = all.first(where: { $0.id == duplicateOfID }) else {
            transaction.duplicateOfID = nil
            try? context.save()
            return nil
        }

        let (keeper, loser) = transaction.createdAt <= other.createdAt ? (transaction, other) : (other, transaction)
        if keeper.attachmentID == nil { keeper.attachmentID = loser.attachmentID }
        if keeper.projectID == nil { keeper.projectID = loser.projectID }
        if keeper.loanID == nil { keeper.loanID = loser.loanID }
        if keeper.counterparty == nil { keeper.counterparty = loser.counterparty }
        if keeper.merchant == nil { keeper.merchant = loser.merchant }
        if (keeper.rawTranscript ?? "").isEmpty { keeper.rawTranscript = loser.rawTranscript }
        keeper.duplicateOfID = nil

        let keeperID = keeper.id
        let keeperCategory = keeper.category
        let keeperContext = keeper.context
        context.delete(loser)
        DecisionLedger.record(
            outcome: .corrected,
            transactionID: keeperID,
            guessedCategory: keeperCategory,
            guessedContext: keeperContext,
            correctedFields: [.merge],
            in: context
        )
        try? context.save()
        return keeper
    }
}
