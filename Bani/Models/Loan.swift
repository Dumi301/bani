import Foundation
import SwiftData

// MARK: - Loan enums

/// The two kinds of debt the whiteboard (Board 2) distinguishes — same tracking
/// surface (sum owed left, % left, payments), DIFFERENT accounting for the
/// interest slice:
/// - `bank`: the interest slice of each payment is a business expense booked
///   against the loan's project (`Loan.projectID`).
/// - `investor`: interest/return is a **cost-of-capital** line that must NEVER
///   appear in any project's P&L — its interest transactions carry `projectID ==
///   nil` and are recognised only through `Transaction.loanID → Loan.kind`.
///
/// Persisted as its `String` rawValue via `Loan.kindRaw`, the same additive-safe
/// discipline as `TransactionDirection` / `ScheduledDirection`: adding a case
/// later only widens the valid set and never rewrites stored rows.
enum LoanKind: String, Codable, CaseIterable, Hashable, Sendable {
    case bank
    case investor

    /// Localized display name (ro + en).
    var label: String {
        switch self {
        case .bank: String(localized: "loan.kind.bank")
        case .investor: String(localized: "loan.kind.investor")
        }
    }

    var systemImage: String {
        switch self {
        case .bank: "building.columns.fill"
        case .investor: "person.2.fill"
        }
    }
}

/// The lifecycle state of a `Loan`. `String`-raw persisted, additive-safe.
enum LoanStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case closed

    var label: String {
        switch self {
        case .active: String(localized: "loan.status.active")
        case .closed: String(localized: "loan.status.closed")
        }
    }
}

// MARK: - SwiftData model

/// v1.2b "Loans + rate-splits" — a piece of *debt* (bank loan or investor /
/// non-bank money) the client tracks alongside projects. A NEW, separate
/// SwiftData entity, so its own fields MAY be non-optional (there are no
/// pre-existing rows to decode NULL from — the direction-crash law
/// (`Bani-2026-08-02`) governs additive columns on the *existing* `Transaction`
/// / `ScheduledItem` tables, not a brand-new entity; same discipline as
/// `Project` / `CustomCategory`). Registering it is a lightweight additive
/// migration; existing `default.store` users migrate in place (proven in
/// `LoanMigrationTests`).
///
/// Money is ALWAYS `Decimal`. The amortization split, the payment ScheduledItem
/// series, and the interest/principal transaction booking all build on this model
/// (`AmortizationSchedule`, `LoanStore`). The `kind` / `status` enums are stored
/// as `String` raw values behind computed accessors — the frozen-seam discipline,
/// so a later case never rewrites existing rows.
@Model
final class Loan {
    var id: UUID
    var name: String
    var lender: String
    /// `LoanKind` rawValue ("bank" / "investor"), read through `kind` below.
    var kindRaw: String
    var principal: Decimal
    var currency: Currency
    /// Nominal annual rate as a percent (e.g. `7.9` for 7.9%). `nil` or `0` ⇒
    /// interest-free: every payment is pure principal.
    var annualRatePercent: Decimal?
    var startDate: Date
    /// Loan term in months. `nil` when only a `fixedMonthlyPayment` is known
    /// (the schedule then runs until the balance is cleared).
    var termMonths: Int?
    /// An explicitly-known monthly payment (e.g. a bank statement figure). When
    /// set it OVERRIDES the computed annuity payment; the interest/principal
    /// split is still derived (`interest = balance × monthlyRate`).
    var fixedMonthlyPayment: Decimal?
    /// The project the loan is attached to. Bank loans usually set this (interest
    /// books against it); investor loans usually leave it `nil` (cost-of-capital,
    /// off every project rollup). Resolved by id-lookup, never a relationship —
    /// the `customCategoryID` / `Transaction.projectID` convention.
    var projectID: UUID?
    /// `LoanStatus` rawValue ("active" / "closed"), read through `status` below.
    var statusRaw: String
    var notes: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        lender: String,
        kind: LoanKind,
        principal: Decimal,
        currency: Currency = .ron,
        annualRatePercent: Decimal? = nil,
        startDate: Date = .now,
        termMonths: Int? = nil,
        fixedMonthlyPayment: Decimal? = nil,
        projectID: UUID? = nil,
        status: LoanStatus = .active,
        notes: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.lender = lender
        self.kindRaw = kind.rawValue
        self.principal = principal
        self.currency = currency
        self.annualRatePercent = annualRatePercent
        self.startDate = startDate
        self.termMonths = termMonths
        self.fixedMonthlyPayment = fixedMonthlyPayment
        self.projectID = projectID
        self.statusRaw = status.rawValue
        self.notes = notes
        self.createdAt = createdAt
    }

    /// Non-optional public accessor for the kind; unknown/legacy raw values fall
    /// back to `.bank`. Kept a plain computed property (never a `#Predicate`
    /// keypath — all loan filtering is in-memory), matching `Transaction.direction`.
    var kind: LoanKind {
        get { LoanKind(rawValue: kindRaw) ?? .bank }
        set { kindRaw = newValue.rawValue }
    }

    /// Non-optional public accessor for the status; unknown values read `.active`.
    var status: LoanStatus {
        get { LoanStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    /// The per-month rate as a `Decimal` fraction (`annualRatePercent / 100 / 12`),
    /// or `0` when the loan is interest-free. The single source of the rate used by
    /// both the schedule and the live booking split — never re-derived elsewhere.
    var monthlyRate: Decimal {
        AmortizationSchedule.monthlyRate(annualRatePercent: annualRatePercent)
    }

    /// The full fixed-rate amortization schedule for this loan (pure; no
    /// `ModelContext`). Empty when the inputs cannot form a schedule (no term and
    /// no fixed payment, or a non-positive principal).
    func schedule(calendar: Calendar = .current) -> [AmortizationPayment] {
        AmortizationSchedule.schedule(
            principal: principal,
            annualRatePercent: annualRatePercent,
            termMonths: termMonths,
            startDate: startDate,
            fixedMonthlyPayment: fixedMonthlyPayment,
            calendar: calendar
        )
    }
}

// MARK: - Snapshot

/// A value-type snapshot of one `Loan`, so views and pure logic can hold a loan's
/// display attributes without a live `ModelContext` — mirrors `ProjectSnapshot` /
/// `CustomCategorySnapshot`.
struct LoanSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let lender: String
    let kind: LoanKind
    let principal: Decimal
    let currency: Currency
    let annualRatePercent: Decimal?
    let startDate: Date
    let termMonths: Int?
    let fixedMonthlyPayment: Decimal?
    let projectID: UUID?
    let status: LoanStatus
    let notes: String
    let createdAt: Date
}

extension Loan {
    var snapshot: LoanSnapshot {
        LoanSnapshot(
            id: id, name: name, lender: lender, kind: kind, principal: principal,
            currency: currency, annualRatePercent: annualRatePercent, startDate: startDate,
            termMonths: termMonths, fixedMonthlyPayment: fixedMonthlyPayment,
            projectID: projectID, status: status, notes: notes, createdAt: createdAt
        )
    }
}
