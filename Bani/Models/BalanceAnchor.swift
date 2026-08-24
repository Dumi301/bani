import Foundation
import SwiftData

// MARK: - SwiftData model

/// v2 "Balance anchoring / reconciliation" — a recorded point of *cash truth*: the
/// client's real bank balance at a moment in time. Liquidity is otherwise computed
/// purely from logged flows, so a single missed expense corrupts the running number
/// silently, forever. An anchor lets the client say "my actual balance today is X"
/// and reset the baseline the drift is measured from (see `ReconciliationEngine`).
///
/// A NEW, separate SwiftData entity, so its own fields MAY be non-optional (there
/// are no pre-existing rows to decode NULL from — the direction-crash law
/// (`Bani-2026-08-02`) governs additive columns on the *existing* `Transaction` /
/// `ScheduledItem` tables, not a brand-new entity; same discipline as `Loan` /
/// `Project`). Registering it is a lightweight additive migration; existing
/// `default.store` users migrate in place (proven in `BalanceAnchorMigrationTests`).
///
/// Money is ALWAYS `Decimal`. An anchor never moves money — it only records reality
/// and resets the drift baseline. The optional closing *adjustment* is an ordinary
/// `Transaction` (see `ReconciliationStore`), auditable and deletable like any
/// other; the anchor itself is a pure marker.
@Model
final class BalanceAnchor {
    var id: UUID
    /// The real balance the client entered, in `currency` (never converted — an
    /// anchor is reality in one account's currency).
    var amount: Decimal
    /// The currency the balance was entered in. Reconciliation counts only flows in
    /// this same currency against this anchor (no cross-currency guessing — see
    /// `ReconciliationEngine`).
    var currency: Currency
    /// The instant the balance was true. The drift baseline: expected balance going
    /// forward = `amount` + net logged flows with `date > anchoredAt`.
    var anchoredAt: Date
    /// The signed drift (`enteredActual − expected`) observed at the moment this
    /// anchor was taken — the honest historical record for the anchor-history list
    /// ("on this date you were N off"). It cannot be recomputed later once flows
    /// change, so it is stored. `0` when the balance matched expectation exactly.
    /// Non-optional (new entity, safe) with a `0` default.
    var driftAtAnchor: Decimal
    /// Optional free-text note the client attached when anchoring.
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        amount: Decimal,
        currency: Currency,
        anchoredAt: Date = .now,
        driftAtAnchor: Decimal = 0,
        note: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.anchoredAt = anchoredAt
        self.driftAtAnchor = driftAtAnchor
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - Snapshot

/// A value-type snapshot of one `BalanceAnchor`, so views and pure logic can hold
/// an anchor without a live `ModelContext` — mirrors `LoanSnapshot` /
/// `ScheduledItemSnapshot`.
struct BalanceAnchorSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let amount: Decimal
    let currency: Currency
    let anchoredAt: Date
    let driftAtAnchor: Decimal
    let note: String?
    let createdAt: Date
}

extension BalanceAnchor {
    var snapshot: BalanceAnchorSnapshot {
        BalanceAnchorSnapshot(
            id: id, amount: amount, currency: currency, anchoredAt: anchoredAt,
            driftAtAnchor: driftAtAnchor, note: note, createdAt: createdAt
        )
    }
}
