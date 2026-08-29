import Foundation
import SwiftData

/// The loan lifecycle seam, kept out of the views so it can be driven directly by
/// tests (no UI). It owns: creating a loan (+ its full payment `ScheduledItem`
/// series), booking a payment as the interest/principal split, and
/// cancelling/re-syncing pending payments on edit/close.
///
/// **Payment-series design.** A loan's payments live as outgoing `ScheduledItem`s
/// so they flow through the liquidity horizon math
/// (`LiquidityCalculator.expectedOut`) with NO extra wiring — this is exactly why
/// `loanAdjustment` stays `.zero` (see `LiquidityCalculator`): the horizon already
/// sees each payment once, through its item. The WHOLE schedule is generated up
/// front as `seriesID`-linked occurrences (so the 30/60/90 horizons can see every
/// payment that falls in the window, each once — `LoanLiquidityTests`), each
/// carrying:
/// - `loanID` — so booking can recover the loan and write the split;
/// - `projectID = loan.projectID` — a bank loan's payments belong to its project
///   (per the whiteboard); investor loans inherit `nil`;
/// - `recurrence = .none` — the occurrences ARE the series (linked by `seriesID`);
///   the monthly cadence is baked into the pre-computed due dates (via P2's
///   `RecurrenceEngine` month math), so no item self-spawns.
///
/// **Booking is schedule-driven and calendar-robust.** A payment item is bound to
/// its `AmortizationSchedule` row by its ordinal position among the loan's items
/// (sorted by due date), NOT by date-equality — so the interest/principal split is
/// always the exact scheduled split for that month, and the amortization table
/// shown in the UI and the transactions actually written agree to the cent.
///
/// **Completion path.** Loan payment items MUST be completed via `bookPayment`
/// (two split transactions), never the generic `ScheduledItemStore.markDone`
/// (which would write a single full-amount transaction). `LoanDetailView` drives
/// `bookPayment`; routing the generic mark-done of a `loanID`-tagged item here is
/// an integration point owned outside this file.
enum LoanStore {

    // MARK: - Validation (M5)

    /// Why a loan's terms were rejected at create/edit.
    enum ValidationError: Error, Equatable {
        /// A fixed monthly payment ≤ the first period's interest: the loan can never
        /// amortize, so its schedule would collapse and understate total interest.
        case fixedPaymentBelowInterest
    }

    /// Validate a loan's terms before it is persisted or re-synced. Throws when a
    /// fixed monthly payment cannot amortize the principal (≤ first-period
    /// interest). The pure predicate lives on `AmortizationSchedule.canAmortize`;
    /// this is the throwing façade the create/edit call sites and tests use.
    static func validate(principal: Decimal, annualRatePercent: Decimal?, fixedMonthlyPayment: Decimal?) throws {
        guard AmortizationSchedule.canAmortize(
            principal: principal, annualRatePercent: annualRatePercent, fixedMonthlyPayment: fixedMonthlyPayment
        ) else {
            throw ValidationError.fixedPaymentBelowInterest
        }
    }

    // MARK: - Create

    /// Insert a new loan, seed the loan-interest category, and generate its full
    /// pending payment series. Each generated item is STAMPED with its
    /// `AmortizationSchedule` row index (M3) so booking binds by schedule row, never
    /// sorted position. Returns the generated items (empty when the loan can't form
    /// a schedule — no term and no fixed payment). Returns empty WITHOUT persisting
    /// when the terms can't amortize (M5: a fixed payment ≤ first-period interest is
    /// rejected, never stored as a collapsed schedule).
    @MainActor
    @discardableResult
    static func createLoan(_ loan: Loan, calendar: Calendar = .current, in modelContext: ModelContext) -> [ScheduledItem] {
        // M5: never persist a non-amortizing loan (its schedule would truncate and
        // understate totalInterest). Reject up front, before any insert.
        guard AmortizationSchedule.canAmortize(
            principal: loan.principal, annualRatePercent: loan.annualRatePercent,
            fixedMonthlyPayment: loan.fixedMonthlyPayment
        ) else { return [] }

        modelContext.insert(loan)
        LoanCategories.seedInterestCategory(in: modelContext)

        let schedule = loan.schedule(calendar: calendar)
        let seriesID = UUID()
        // Stamp each payment with its 0-based schedule row index (M3).
        let items = schedule.indices.map {
            paymentItem(for: loan, row: schedule[$0], scheduleIndex: $0, seriesID: seriesID)
        }
        for item in items { modelContext.insert(item) }
        try? modelContext.save()
        return items
    }

    // MARK: - Book a payment (interest + principal split)

    /// The two linked transactions a booked loan payment produces.
    struct BookedPayment: Equatable {
        let interest: Transaction
        let principal: Transaction
    }

    /// Complete one loan payment: write the interest slice (expense; bank → the
    /// loan's project, investor → `nil` cost-of-capital) and the principal slice
    /// (`neutral`; never an expense anywhere), both tagged with `loanID` and the
    /// lender as counterparty. Marks the item done and links the interest tx.
    /// Booking the loan's final payment closes it. Returns `nil` — booking nothing
    /// — when the item is already done (idempotence guard) or unbindable.
    @MainActor
    @discardableResult
    static func bookPayment(
        _ item: ScheduledItem,
        loan: Loan,
        date: Date = .now,
        calendar: Calendar = .current,
        in modelContext: ModelContext
    ) -> BookedPayment? {
        // Idempotence: a done item never books again (no double booking).
        guard item.status == .pending else { return nil }

        let siblings = loanItems(loanID: loan.id, in: modelContext).sorted { $0.dueDate < $1.dueDate }
        let schedule = loan.schedule(calendar: calendar)

        // M3: bind the payment to its EXACT schedule row by its persisted stamp, so
        // the interest/principal split is right regardless of sort order,
        // out-of-order booking, or a mid-life edit. Legacy items written before the
        // stamp existed carry no stamp → fall back to due-date order (the old
        // behaviour, correct for in-order booking of a legacy series).
        let scheduleIndex: Int
        if let stamp = item.scheduleIndex {
            scheduleIndex = stamp
        } else {
            guard let ordinal = siblings.firstIndex(where: { $0.id == item.id }) else { return nil }
            scheduleIndex = ordinal
        }
        guard scheduleIndex >= 0, scheduleIndex < schedule.count else { return nil }
        let row = schedule[scheduleIndex]

        // Interest slice — expense. Bank books against the loan's project; investor
        // is cost-of-capital and carries NO project (recovered via loanID→kind).
        let interestTx = Transaction(
            amount: row.interest,
            currency: loan.currency,
            context: .work,
            customCategoryID: LoanCategories.interestCategoryID,
            descriptionText: String(localized: "loan.tx.interest \(loan.name)"),
            date: date,
            source: .manual,
            direction: .expense,
            counterparty: loan.lender,
            projectID: loan.kind == .bank ? loan.projectID : nil,
            loanID: loan.id
        )
        // Principal slice — neutral balance movement; never an expense, so never in
        // any project P&L (project attribution is irrelevant → nil).
        let principalTx = Transaction(
            amount: row.principal,
            currency: loan.currency,
            context: .work,
            descriptionText: String(localized: "loan.tx.principal \(loan.name)"),
            date: date,
            source: .manual,
            direction: .neutral,
            counterparty: loan.lender,
            projectID: nil,
            loanID: loan.id
        )
        modelContext.insert(interestTx)
        modelContext.insert(principalTx)

        item.status = .done
        item.linkedTransactionID = interestTx.id

        // The loan closes once no pending payment items remain.
        let stillPending = siblings.contains { $0.id != item.id && $0.status == .pending }
        if !stillPending { loan.status = .closed }

        try? modelContext.save()
        return BookedPayment(interest: interestTx, principal: principalTx)
    }

    // MARK: - Edit / close

    /// Recompute pending payments after a loan edit: drop the loan's pending items
    /// and regenerate a fresh series for the still-unpaid schedule rows (skipping
    /// the rows already booked). Booked (done) items and their transactions are
    /// never touched. A closed loan is left with no pending items.
    @MainActor
    static func syncPendingPayment(for loan: Loan, calendar: Calendar = .current, in modelContext: ModelContext) {
        let seriesID = deletePendingItems(for: loan.id, in: modelContext) ?? UUID()
        guard loan.status == .active else { try? modelContext.save(); return }

        let schedule = loan.schedule(calendar: calendar)
        let bookedCount = countBookedPayments(for: loan.id, in: modelContext)
        guard bookedCount < schedule.count else { try? modelContext.save(); return }

        // Regenerate the still-unpaid rows, each STAMPED with its TRUE schedule row
        // index (M3): indices `bookedCount ..< count` are exactly those rows, so a
        // payment booked after an edit still binds to the right split.
        for index in bookedCount..<schedule.count {
            modelContext.insert(paymentItem(for: loan, row: schedule[index], scheduleIndex: index, seriesID: seriesID))
        }
        try? modelContext.save()
    }

    /// Close a loan: mark it closed and cancel every remaining pending payment
    /// (booked transactions stay — a real, already-logged payment is never undone).
    @MainActor
    static func closeLoan(_ loan: Loan, in modelContext: ModelContext) {
        loan.status = .closed
        _ = deletePendingItems(for: loan.id, in: modelContext)
        try? modelContext.save()
    }

    // MARK: - Position (sum owed left / % left)

    /// A loan's live debt position, derived from the schedule + booked principal.
    struct LoanPosition: Equatable, Sendable {
        /// Remaining principal owed (never negative).
        var outstanding: Decimal
        /// Principal repaid so far (`principal − outstanding`).
        var paidPrincipal: Decimal
        /// Percent of principal still owed (`outstanding / principal × 100`), 0..100.
        var percentLeft: Decimal
        /// Number of payments already booked.
        var paymentsBooked: Int
    }

    /// Compute the loan's position from its booked principal slices. "Sum owed
    /// left" = outstanding principal; "% left" = outstanding ÷ principal × 100.
    @MainActor
    static func position(for loan: Loan, in modelContext: ModelContext) -> LoanPosition {
        let outstanding = outstandingPrincipal(for: loan, in: modelContext)
        let paid = loan.principal - outstanding
        let pct = loan.principal > 0
            ? AmortizationSchedule.rounded2(outstanding / loan.principal * 100)
            : 0
        return LoanPosition(outstanding: outstanding, paidPrincipal: paid,
                            percentLeft: pct, paymentsBooked: countBookedPayments(for: loan.id, in: modelContext))
    }

    /// Outstanding principal = original principal − Σ booked principal slices
    /// (the `neutral`, loan-tagged transactions). Clamped at 0.
    @MainActor
    static func outstandingPrincipal(for loan: Loan, in modelContext: ModelContext) -> Decimal {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let paid = all
            .filter { $0.loanID == loan.id && $0.direction == .neutral }
            .reduce(Decimal(0)) { $0 + $1.amount }
        let remaining = loan.principal - paid
        return remaining > 0 ? remaining : 0
    }

    // MARK: - Internals

    /// All scheduled items for a loan (done + pending). In-memory filter — the
    /// codebase convention keeps enum/optional comparisons out of `#Predicate`
    /// keypaths.
    @MainActor
    private static func loanItems(loanID: UUID, in modelContext: ModelContext) -> [ScheduledItem] {
        let all = (try? modelContext.fetch(FetchDescriptor<ScheduledItem>())) ?? []
        return all.filter { $0.loanID == loanID }
    }

    /// Count of payments already booked for a loan = number of principal (neutral)
    /// slices written for it.
    @MainActor
    private static func countBookedPayments(for loanID: UUID, in modelContext: ModelContext) -> Int {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.filter { $0.loanID == loanID && $0.direction == .neutral }.count
    }

    /// Delete all pending items for a loan; returns the series id they shared (so a
    /// re-synced series stays linked), or `nil` if there were none.
    @MainActor
    @discardableResult
    private static func deletePendingItems(for loanID: UUID, in modelContext: ModelContext) -> UUID? {
        let all = (try? modelContext.fetch(FetchDescriptor<ScheduledItem>())) ?? []
        var seriesID: UUID?
        for item in all where item.loanID == loanID && item.status == .pending {
            if seriesID == nil { seriesID = item.seriesID }
            modelContext.delete(item)
        }
        return seriesID
    }

    /// Build one pending payment `ScheduledItem` for a schedule row (outgoing,
    /// loan-tagged, project = loan's project; `recurrence = .none` — the series is
    /// the set of pre-generated occurrences, linked by `seriesID`).
    private static func paymentItem(for loan: Loan, row: AmortizationPayment, scheduleIndex: Int, seriesID: UUID) -> ScheduledItem {
        ScheduledItem(
            direction: .outgoing,
            amount: row.payment,
            currency: loan.currency,
            title: loan.name,
            counterparty: loan.lender,
            dueDate: row.dueDate,
            projectID: loan.projectID,
            status: .pending,
            recurrence: .none,
            seriesID: seriesID,
            loanID: loan.id,
            scheduleIndex: scheduleIndex
        )
    }
}
