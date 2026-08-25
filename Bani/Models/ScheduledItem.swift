import Foundation
import SwiftData

// MARK: - Scheduled money enums

/// Which way scheduled money flows. Persisted as its `String` rawValue (additive-
/// safe, same discipline as `TransactionDirection`). Maps to a real
/// `TransactionDirection` when an item is fulfilled: `.incoming → .income`,
/// `.outgoing → .expense`.
enum ScheduledDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case incoming
    case outgoing

    /// Localized display name (ro + en).
    var label: String {
        switch self {
        case .incoming: String(localized: "scheduled.direction.incoming")
        case .outgoing: String(localized: "scheduled.direction.outgoing")
        }
    }

    var systemImage: String {
        switch self {
        case .incoming: "arrow.down.left"
        case .outgoing: "arrow.up.right"
        }
    }

    /// The `TransactionDirection` a fulfilled item becomes (mark-done flow).
    var transactionDirection: TransactionDirection {
        switch self {
        case .incoming: .income
        case .outgoing: .expense
        }
    }
}

/// Lifecycle of a scheduled item. `String`-raw persisted, additive-safe.
enum ScheduledStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case done

    var label: String {
        switch self {
        case .pending: String(localized: "scheduled.status.pending")
        case .done:    String(localized: "scheduled.status.done")
        }
    }
}

/// How often a `ScheduledItem` recurs (v1.2a follow-up "Recurring ScheduledItems").
/// Persisted as its raw `String` via `ScheduledItem.recurrenceRaw` - additive-safe,
/// same discipline as `ScheduledDirection` / `ScheduledStatus`. `.none` is the
/// default: a one-shot item, unchanged behaviour. Mark-done on a recurring item
/// generates its next occurrence (see `RecurrenceEngine` + `ScheduledItemStore`).
enum RecurrenceRule: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case weekly
    case monthly
    case quarterly
    case yearly

    /// Localized display name (ro + en) for the edit-sheet picker.
    var label: String {
        switch self {
        case .none: String(localized: "scheduled.recurrence.none")
        case .weekly: String(localized: "scheduled.recurrence.weekly")
        case .monthly: String(localized: "scheduled.recurrence.monthly")
        case .quarterly: String(localized: "scheduled.recurrence.quarterly")
        case .yearly: String(localized: "scheduled.recurrence.yearly")
        }
    }
}

// MARK: - SwiftData model

/// v1.2a "Projects Core" — a piece of *scheduled money*: an expected incoming or
/// outgoing payment with a due date. First-class information (not a todo app): it
/// exists so the client can judge liquidity ("can I enter another investment?")
/// and never lose track of who owes whom.
///
/// A NEW, separate SwiftData entity — additive/lightweight migration, existing
/// data untouched (proven in `ProjectMigrationTests`). "Overdue" is COMPUTED
/// (`pending && dueDate < now`), never stored, so it can never drift stale.
///
/// - `counterparty` is free text (a Person registry lands in a later run).
/// - `projectID` is the analytical lens this item belongs to (nil = unassigned).
/// - `linkedTransactionID` is set when the item is fulfilled: marking it done
///   creates a real `Transaction` and records its id here, flipping `status`.
@Model
final class ScheduledItem {
    var id: UUID
    var direction: ScheduledDirection
    var amount: Decimal
    var currency: Currency
    var title: String
    var descriptionText: String
    var counterparty: String?
    var dueDate: Date
    var projectID: UUID?
    var status: ScheduledStatus
    var linkedTransactionID: UUID?
    /// Recurring ScheduledItems (v2) - STORED as an **Optional** `String` raw
    /// value. `Bani-2026-08-02` law: a non-optional additive column left legacy
    /// `Transaction` rows NULL -> dynamic-cast SIGABRT the moment they faulted.
    /// Every `ScheduledItem` row written before this run has no such column at
    /// all, so it decodes to `nil` here - a legal Optional decode, zero data
    /// loss - and reads as `.none` through the `recurrence` accessor below. This
    /// is a NEW column (never previously named under any other name), so unlike
    /// `Transaction.directionStored` it needs no `@Attribute(originalName:)`.
    /// Copies the exact optional-backed discipline of `Transaction.direction`.
    var recurrenceRaw: String?
    /// Non-optional public accessor: legacy/nil rows read `.none`; writes go
    /// through to the optional backing store. Kept a plain computed property
    /// (never used in a `#Predicate`/`SortDescriptor` keypath - all recurrence
    /// filtering is in-memory), matching `Transaction.direction`.
    var recurrence: RecurrenceRule {
        get { recurrenceRaw.flatMap(RecurrenceRule.init(rawValue:)) ?? .none }
        set { recurrenceRaw = newValue.rawValue }
    }
    /// Links every occurrence generated from one recurring item together (the v2
    /// Loans payment-series seam builds on this). `nil` for a one-shot item AND
    /// for every pre-recurrence row - additive + optional, same lightweight-
    /// migration discipline as `projectID` / `customCategoryID`. Minted on first
    /// use by `ScheduledItemStore` when a recurring item is marked done; deleting
    /// one occurrence never cascades to the rest of its series.
    var seriesID: UUID?
    /// v1.2b "Loans" — the `Loan` whose payment series this item belongs to
    /// (`Loan.id`), set on every generated loan-payment occurrence. Optional +
    /// additive, the same lightweight-migration discipline as `projectID` /
    /// `seriesID`: legacy rows decode to `nil` (a legal Optional decode, zero data
    /// loss — the `Bani-2026-08-02` law), and read as "not a loan payment". `nil`
    /// for every ordinary scheduled item. Loan-payment items MUST be completed
    /// through `LoanStore.bookPayment` (which books the interest/principal split
    /// and advances the series), never the generic `ScheduledItemStore.markDone`;
    /// they carry `projectID == nil` so they never surface in a per-project
    /// mark-done pane (their project attribution lives on `Loan.projectID`).
    var loanID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        direction: ScheduledDirection,
        amount: Decimal,
        currency: Currency,
        title: String,
        descriptionText: String = "",
        counterparty: String? = nil,
        dueDate: Date,
        projectID: UUID? = nil,
        status: ScheduledStatus = .pending,
        linkedTransactionID: UUID? = nil,
        recurrence: RecurrenceRule = .none,
        seriesID: UUID? = nil,
        loanID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.direction = direction
        self.amount = amount
        self.currency = currency
        self.title = title
        self.descriptionText = descriptionText
        self.counterparty = counterparty
        self.dueDate = dueDate
        self.projectID = projectID
        self.status = status
        self.linkedTransactionID = linkedTransactionID
        self.recurrenceRaw = recurrence.rawValue
        self.seriesID = seriesID
        self.loanID = loanID
        self.createdAt = createdAt
    }

    /// COMPUTED, never stored: a pending item whose due date has passed. Kept a
    /// plain computed property (never a `#Predicate`/`SortDescriptor` keypath —
    /// overdue filtering is always in-memory), so no fetch site needs it.
    func isOverdue(asOf now: Date = .now) -> Bool {
        status == .pending && dueDate < now
    }
}

// MARK: - Snapshot

/// A value-type snapshot of one `ScheduledItem`, so views/pure logic
/// (`LiquidityCalculator`, schedule list, notification scheduler) work without a
/// live `ModelContext` — mirrors `CustomCategorySnapshot`.
struct ScheduledItemSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let direction: ScheduledDirection
    let amount: Decimal
    let currency: Currency
    let title: String
    let descriptionText: String
    let counterparty: String?
    let dueDate: Date
    let projectID: UUID?
    let status: ScheduledStatus
    let linkedTransactionID: UUID?
    let createdAt: Date

    /// COMPUTED overdue, mirroring the model accessor.
    func isOverdue(asOf now: Date = .now) -> Bool {
        status == .pending && dueDate < now
    }
}

extension ScheduledItem {
    var snapshot: ScheduledItemSnapshot {
        ScheduledItemSnapshot(
            id: id, direction: direction, amount: amount, currency: currency,
            title: title, descriptionText: descriptionText, counterparty: counterparty,
            dueDate: dueDate, projectID: projectID, status: status,
            linkedTransactionID: linkedTransactionID, createdAt: createdAt
        )
    }
}
