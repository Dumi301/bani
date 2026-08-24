import Foundation

// MARK: - Value inputs

/// A transaction reduced to what the Raport hub needs — a pure value type so the
/// whole hub model is unit-testable with no SwiftData (mirrors `ProjectTxLine` /
/// `ReconciliationFlow`). Carries `loanID` so a loan's outstanding principal (its
/// booked `neutral` slices) can be summed without a `ModelContext`.
struct RaportTxLine: Equatable, Sendable {
    var amount: Decimal
    var currency: Currency
    var direction: TransactionDirection
    var projectID: UUID?
    var loanID: UUID?
    var date: Date

    /// The `ProjectTxLine` view of this line, for the shared project aggregators.
    var projectLine: ProjectTxLine {
        ProjectTxLine(amount: amount, currency: currency, direction: direction, projectID: projectID, date: date)
    }
}

// MARK: - Section models

/// The Position block: the anchor-aware net logged position, the liquidity answer
/// over the chosen horizon (both from the same numbers the Projects tab shows, so
/// the two never disagree), and cash flow over the selected period.
struct RaportPosition: Equatable, Sendable {
    var netLoggedPosition: Decimal
    var liquidity: LiquidityResult
    var cashIn: Decimal
    var cashOut: Decimal
    var cashHasUnconvertible: Bool
    /// Net cash flow over the period (in − out).
    var cashNet: Decimal { cashIn - cashOut }
}

/// One debt line (bank or investor loan): live position + the split of the next
/// payment + where the interest slice books (bank only; investors are off every
/// project rollup).
struct RaportDebtRow: Equatable, Sendable, Identifiable {
    var loanID: UUID
    var name: String
    var lender: String
    var kind: LoanKind
    var currency: Currency
    /// Remaining principal owed (never negative) — "sum owed left".
    var outstanding: Decimal
    /// Percent of principal still owed, 0…100 — "% left".
    var percentLeft: Decimal
    /// Total of the next pending payment, or `nil` when nothing is pending.
    var nextPayment: Decimal?
    /// Interest slice of the next payment (the amount that books to the project /
    /// cost-of-capital), or `nil`.
    var nextInterest: Decimal?
    /// Principal slice of the next payment, or `nil`.
    var nextPrincipal: Decimal?
    var nextDueDate: Date?
    /// The project the interest slice books against (BANK loans only). Investor
    /// interest is cost-of-capital and carries no project — always `nil` here.
    var bookedToProjectID: UUID?
    var bookedToProjectName: String?
    /// Lifetime interest across the whole amortization schedule — the cost of this
    /// capital.
    var totalInterest: Decimal

    var id: UUID { loanID }
}

/// A debt section (bank OR investor): its rows + roll-up totals. `costOfCapital` is
/// the sum of lifetime interest — the meaningful "what this money costs" line for
/// the investor section (VISION §2: a cost-of-capital line OUTSIDE all project
/// rollups).
struct RaportDebtSection: Equatable, Sendable {
    var rows: [RaportDebtRow]
    var totalOutstanding: Decimal
    var costOfCapital: Decimal

    static let empty = RaportDebtSection(rows: [], totalOutstanding: 0, costOfCapital: 0)
    var isEmpty: Bool { rows.isEmpty }
}

/// One project's roll-up: capital invested (Σ expenses scoped to it) + the
/// forward-looking budgeting view — unfinished (outgoing, non-loan) scheduled
/// payments as paid / due / % / next date.
struct RaportProjectRow: Equatable, Sendable, Identifiable {
    var projectID: UUID
    var name: String
    var colorIndex: Int
    /// Capital deployed into the project = Σ expenses scoped to it (RON).
    var invested: Decimal
    /// Net position = received − spent (RON).
    var net: Decimal
    /// Σ of DONE outgoing (non-loan) scheduled payments for the project.
    var paid: Decimal
    /// Σ of PENDING outgoing (non-loan) scheduled payments for the project.
    var due: Decimal
    /// Percent of the committed total already paid, 0…100 (0 when nothing committed).
    var percentPaid: Decimal
    var nextDueDate: Date?

    var id: UUID { projectID }
    /// Total committed outgoing = paid + due.
    var committed: Decimal { paid + due }
    /// True when the project has any scheduled-payment commitments to budget.
    var hasBudget: Bool { committed > 0 }
}

// MARK: - The assembled hub

/// The whole Raport hub as one value — every section computed. Pure, so
/// `RaportModelTests` asserts it against a seeded in-memory container and the
/// SwiftUI `RaportHubView` is a thin render of it.
struct RaportHubModel: Equatable, Sendable {
    var position: RaportPosition
    var receivables: ReceivablesSummary
    var bankDebt: RaportDebtSection
    var investorDebt: RaportDebtSection
    var projects: [RaportProjectRow]
}

// MARK: - Builder

/// Pure assembly of the Raport hub from value inputs — the same discipline as
/// `LiquidityCalculator` / `ProjectAnalytics` / `ReconciliationEngine`. No
/// `ModelContext`, no side effects, so it is deterministic and unit-testable; the
/// view feeds it its `@Query` results mapped to value types.
enum RaportHubBuilder {

    /// RON value of an amount, mirroring `ProjectAnalytics.ronValue` (EUR converts
    /// only when a rate exists; otherwise the raw amount passes through and the
    /// caller flags it).
    private static func ron(_ amount: Decimal, _ currency: Currency, rate: Decimal?) -> Decimal? {
        switch currency {
        case .ron: return amount
        case .eur: return rate.map { amount * $0 }
        }
    }

    static func build(
        lines: [RaportTxLine],
        loans: [LoanSnapshot],
        projects: [ProjectSnapshot],
        items: [ScheduledItemSnapshot],
        rate: Double?,
        horizon: LiquidityHorizon,
        cashflowInterval: DateInterval,
        // IDs of scheduled items that are loan payments (`ScheduledItem.loanID != nil`).
        // `ScheduledItemSnapshot` intentionally omits `loanID`, so the caller passes
        // this set; the project budgeting rows exclude these so loan debt-service is
        // counted only once, in the dedicated Debt sections.
        loanItemIDs: Set<UUID> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> RaportHubModel {
        let rateDecimal = rate.map { Decimal($0) }
        let projectLines = lines.map(\.projectLine)

        // ── Position ──
        let netLogged = ProjectAnalytics.netLoggedPosition(projectLines, rate: rateDecimal)
        let pendingSnapshots = items.filter { $0.status == .pending }
        let liquidity = LiquidityCalculator.result(
            netLoggedPosition: netLogged,
            pendingItems: pendingSnapshots,
            horizon: horizon,
            rate: rateDecimal,
            now: now
        )
        var cashIn: Decimal = 0
        var cashOut: Decimal = 0
        var cashUnconvertible = false
        for line in lines where line.date >= cashflowInterval.start && line.date < cashflowInterval.end {
            guard line.direction != .neutral else { continue }
            guard let value = ron(line.amount, line.currency, rate: rateDecimal) else {
                cashUnconvertible = true
                continue
            }
            if line.direction == .income { cashIn += value } else { cashOut += value }
        }
        let position = RaportPosition(
            netLoggedPosition: netLogged, liquidity: liquidity,
            cashIn: cashIn, cashOut: cashOut, cashHasUnconvertible: cashUnconvertible
        )

        // ── Receivables (reuses the P6 rollup unchanged) ──
        let receivables = ReceivablesRollup.build(items, rate: rate)

        // ── Debt (bank + investor) ──
        let projectName: (UUID?) -> String? = { id in
            guard let id else { return nil }
            return projects.first { $0.id == id }?.name
        }
        var bankRows: [RaportDebtRow] = []
        var investorRows: [RaportDebtRow] = []
        for loan in loans where loan.status == .active {
            let row = debtRow(for: loan, lines: lines, projectName: projectName, calendar: calendar)
            if loan.kind == .bank { bankRows.append(row) } else { investorRows.append(row) }
        }
        let bankDebt = section(bankRows)
        let investorDebt = section(investorRows)

        // ── Projects (invested + budgeting) ──
        let projectRows: [RaportProjectRow] = projects
            .filter { !$0.archived }
            .map { projectRow(for: $0, lines: lines, items: items, loanItemIDs: loanItemIDs, rate: rateDecimal, calendar: calendar) }

        return RaportHubModel(
            position: position, receivables: receivables,
            bankDebt: bankDebt, investorDebt: investorDebt, projects: projectRows
        )
    }

    // MARK: - Per-loan

    private static func debtRow(
        for loan: LoanSnapshot,
        lines: [RaportTxLine],
        projectName: (UUID?) -> String?,
        calendar: Calendar
    ) -> RaportDebtRow {
        // Outstanding = principal − Σ booked principal (neutral, loan-tagged) slices.
        // This is the exact `LoanStore.position` definition, computed purely here.
        // (`RaportTxLine` carries `loanID`; `ScheduledItemSnapshot` does not, so the
        // next-payment split is read from the schedule, not the pending item.)
        let bookedSlices = lines.filter { $0.loanID == loan.id && $0.direction == .neutral }
        let bookedPrincipal = bookedSlices.reduce(Decimal(0)) { $0 + $1.amount }
        let bookedCount = bookedSlices.count
        let outstanding = max(0, loan.principal - bookedPrincipal)
        let percentLeft = loan.principal > 0
            ? AmortizationSchedule.rounded2(outstanding / loan.principal * 100)
            : 0

        let schedule = AmortizationSchedule.schedule(
            principal: loan.principal,
            annualRatePercent: loan.annualRatePercent,
            termMonths: loan.termMonths,
            startDate: loan.startDate,
            fixedMonthlyPayment: loan.fixedMonthlyPayment,
            calendar: calendar
        )
        // The next unbooked schedule row IS the next payment (amount, due date, and
        // the interest/principal split), bound by ordinal — the exact row
        // `LoanStore.bookPayment` will book next.
        let nextRow: AmortizationPayment? = bookedCount < schedule.count ? schedule[bookedCount] : nil

        let bookedToProjectID = loan.kind == .bank ? loan.projectID : nil
        return RaportDebtRow(
            loanID: loan.id,
            name: loan.name,
            lender: loan.lender,
            kind: loan.kind,
            currency: loan.currency,
            outstanding: outstanding,
            percentLeft: percentLeft,
            nextPayment: nextRow?.payment,
            nextInterest: nextRow?.interest,
            nextPrincipal: nextRow?.principal,
            nextDueDate: nextRow?.dueDate,
            bookedToProjectID: bookedToProjectID,
            bookedToProjectName: projectName(bookedToProjectID),
            totalInterest: AmortizationSchedule.totalInterest(schedule)
        )
    }

    private static func section(_ rows: [RaportDebtRow]) -> RaportDebtSection {
        RaportDebtSection(
            rows: rows,
            totalOutstanding: rows.reduce(Decimal(0)) { $0 + $1.outstanding },
            costOfCapital: rows.reduce(Decimal(0)) { $0 + $1.totalInterest }
        )
    }

    // MARK: - Per-project

    private static func projectRow(
        for project: ProjectSnapshot,
        lines: [RaportTxLine],
        items: [ScheduledItemSnapshot],
        loanItemIDs: Set<UUID>,
        rate: Decimal?,
        calendar: Calendar
    ) -> RaportProjectRow {
        let scoped = lines.filter { $0.projectID == project.id }.map(\.projectLine)
        let totals = ProjectAnalytics.totals(scoped, rate: rate)

        // Budgeting = outgoing, NON-loan scheduled payments scoped to the project.
        // Loan-payment items live in the dedicated Debt sections, so they are
        // excluded here (by id) to avoid double-representing the same commitment.
        let projectItems = items.filter { $0.projectID == project.id && !loanItemIDs.contains($0.id) && $0.direction == .outgoing }
        func ronOrRaw(_ amount: Decimal, _ currency: Currency) -> Decimal {
            switch currency {
            case .ron: return amount
            case .eur: return rate.map { amount * $0 } ?? amount
            }
        }
        var paid: Decimal = 0
        var due: Decimal = 0
        var nextDue: Date?
        for item in projectItems {
            let value = ronOrRaw(item.amount, item.currency)
            switch item.status {
            case .done: paid += value
            case .pending:
                due += value
                if let current = nextDue { nextDue = min(current, item.dueDate) } else { nextDue = item.dueDate }
            }
        }
        let committed = paid + due
        let percentPaid = committed > 0 ? AmortizationSchedule.rounded2(paid / committed * 100) : 0

        return RaportProjectRow(
            projectID: project.id,
            name: project.name,
            colorIndex: project.colorIndex,
            invested: totals.spent,
            net: totals.net,
            paid: paid,
            due: due,
            percentPaid: percentPaid,
            nextDueDate: nextDue
        )
    }
}
