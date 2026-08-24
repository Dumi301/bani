import Foundation
import SwiftData

/// The reconciliation lifecycle seam, kept out of the views so it can be driven
/// directly by tests (no UI) — the same discipline as `LoanStore` /
/// `ScheduledItemStore`. It owns: snapshotting the logged flows + the latest anchor,
/// computing the current drift, and the two commit paths from the drift screen —
/// **create-adjustment-and-anchor** (write the closing `Transaction`, then record
/// the reality point) and **anchor-only** (record reality, reset the drift baseline,
/// write no adjustment).
///
/// **Why the closing adjustment closes the drift exactly.** The always-on-top
/// portfolio number is `ProjectAnalytics.netLoggedPosition` = Σ income − Σ expense
/// (neutral excluded). `ReconciliationEngine` computes `expected` on the *same*
/// basis, so `drift = actual − expected` and an adjustment of `|drift|` in the
/// direction of its sign (`.income` for a positive drift, `.expense` for a negative
/// one) moves `netLoggedPosition` by exactly `drift` — leaving it equal to the
/// entered reality. That is the acceptance property (`ReconciliationFlowTests`).
///
/// **The adjustment never pollutes a project P&L.** It carries `projectID == nil`
/// (whole-portfolio cash truth, not a project's lens) and `loanID == nil`, and is an
/// ordinary `Transaction` — auditable and deletable like any other.
enum ReconciliationStore {

    // MARK: - Snapshot inputs

    /// Snapshot every logged transaction as a reconciliation flow (pure value types
    /// for the engine). All-time; the engine windows by the anchor date.
    @MainActor
    static func flows(in modelContext: ModelContext) -> [ReconciliationFlow] {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.map {
            ReconciliationFlow(amount: $0.amount, currency: $0.currency,
                               direction: $0.direction, date: $0.date)
        }
    }

    /// The latest anchor of `currency` (by `anchoredAt`), or `nil`. Same-currency
    /// only: a RON reconcile uses the latest RON anchor, a EUR reconcile the latest
    /// EUR anchor (the multi-currency rule — see `ReconciliationEngine`). In-memory
    /// filter keeps enum/optional comparisons out of `#Predicate` keypaths, the
    /// codebase convention.
    @MainActor
    static func latestAnchor(currency: Currency, in modelContext: ModelContext) -> BalanceAnchor? {
        let all = (try? modelContext.fetch(FetchDescriptor<BalanceAnchor>())) ?? []
        return all.filter { $0.currency == currency }.max { $0.anchoredAt < $1.anchoredAt }
    }

    /// Every anchor, newest first — the anchor-history list (date, amount,
    /// drift-at-time).
    @MainActor
    static func anchorHistory(in modelContext: ModelContext) -> [BalanceAnchorSnapshot] {
        let all = (try? modelContext.fetch(FetchDescriptor<BalanceAnchor>())) ?? []
        return all.sorted { $0.anchoredAt > $1.anchoredAt }.map(\.snapshot)
    }

    // MARK: - Compute

    /// The current reconciliation result for an entered actual balance + currency,
    /// against the logged flows and the latest same-currency anchor.
    @MainActor
    static func result(
        actual: Decimal,
        currency: Currency,
        in modelContext: ModelContext
    ) -> ReconciliationResult {
        let anchorSnapshot = latestAnchor(currency: currency, in: modelContext).map {
            ReconciliationAnchor(amount: $0.amount, currency: $0.currency, anchoredAt: $0.anchoredAt)
        }
        return ReconciliationEngine.reconcile(
            actual: actual, currency: currency, anchor: anchorSnapshot,
            flows: flows(in: modelContext)
        )
    }

    // MARK: - Commit

    /// The outcome of a commit: the anchor recorded, and the closing adjustment
    /// written (or `nil` when the drift was zero, or on the anchor-only path).
    struct Commit: Equatable {
        let anchor: BalanceAnchor
        let adjustment: Transaction?
    }

    /// Create the closing adjustment (unless the drift is zero) and record a new
    /// anchor at the entered reality. After this, `netLoggedPosition` equals the
    /// anchored reality (the acceptance property).
    ///
    /// - `now` is used for BOTH the adjustment's `date` and the anchor's
    ///   `anchoredAt`, so the adjustment sits exactly on the new baseline instant and
    ///   is never re-counted by the next reconcile (the engine windows with `date >
    ///   anchoredAt`).
    /// - `referenceDate` is the date the note reads "vs anchor <date>" (the prior
    ///   anchor's date when one exists, else `now`).
    @MainActor
    @discardableResult
    static func createAdjustmentAndAnchor(
        result: ReconciliationResult,
        note: String? = nil,
        now: Date = .now,
        referenceDate: Date? = nil,
        in modelContext: ModelContext
    ) -> Commit {
        var adjustment: Transaction?
        if let direction = result.adjustmentDirection, result.adjustmentAmount > 0 {
            ReconciliationCategories.seedAdjustmentCategory(in: modelContext)
            let refDay = (referenceDate ?? now).formatted(.dateTime.day().month(.abbreviated).year())
            let tx = Transaction(
                amount: result.adjustmentAmount,
                currency: result.currency,
                context: .personal,
                customCategoryID: ReconciliationCategories.adjustmentCategoryID,
                descriptionText: String(localized: "reconcile.tx.note \(refDay)"),
                date: now,
                rawTranscript: nil,
                source: .manual,
                direction: direction,
                projectID: nil,   // NEVER a project — must not pollute any project P&L
                loanID: nil,
                createdAt: now
            )
            modelContext.insert(tx)
            adjustment = tx
        }
        let anchor = insertAnchor(result: result, note: note, now: now, in: modelContext)
        try? modelContext.save()
        return Commit(anchor: anchor, adjustment: adjustment)
    }

    /// Record reality WITHOUT a closing adjustment: mark the point and reset the
    /// drift baseline to `result.actual`, writing no transaction. The next reconcile
    /// measures drift from here.
    @MainActor
    @discardableResult
    static func anchorOnly(
        result: ReconciliationResult,
        note: String? = nil,
        now: Date = .now,
        in modelContext: ModelContext
    ) -> BalanceAnchor {
        let anchor = insertAnchor(result: result, note: note, now: now, in: modelContext)
        try? modelContext.save()
        return anchor
    }

    // MARK: - Internals

    /// Insert the anchor row (amount = the entered reality; `driftAtAnchor` = the
    /// drift observed at this reconcile, for the history list). Not saved — callers
    /// batch the save.
    @MainActor
    private static func insertAnchor(
        result: ReconciliationResult,
        note: String?,
        now: Date,
        in modelContext: ModelContext
    ) -> BalanceAnchor {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = BalanceAnchor(
            amount: result.actual,
            currency: result.currency,
            anchoredAt: now,
            driftAtAnchor: result.drift,
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )
        modelContext.insert(anchor)
        return anchor
    }
}
