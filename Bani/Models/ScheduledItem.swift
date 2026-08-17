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
