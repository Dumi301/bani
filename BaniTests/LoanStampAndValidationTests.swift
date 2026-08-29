import XCTest
import SwiftData
@testable import Bani

/// v2.2 bugfix lane (books real money — precision matters). Pins the four loan/
/// scheduling fixes:
///   • M1 — `ScheduledItemStore.markDone` is idempotent on the generic (non-loan)
///     path: a double-tap books exactly ONE transaction, never orphaning the first.
///   • M3 — a loan payment binds to its EXACT amortization row by a persisted
///     schedule STAMP (`ScheduledItem.scheduleIndex`), so out-of-order booking and
///     mid-life edits still book the right interest/principal split; legacy
///     unstamped items fall back to due-date order.
///   • M4 — the Raport next-payment preview equals the row `bookPayment` will book
///     next (the lowest-stamped pending item), even in out-of-order state.
///   • M5 — a fixed payment that can't amortize (≤ first-period interest) is
///     rejected at create/edit; a legacy truncated schedule sets an explicit flag
///     so cost-of-capital is never SILENTLY understated.
@MainActor
final class LoanStampAndValidationTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, ScheduledItem.self, Project.self, Loan.self, CustomCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func transactions(_ ctx: ModelContext) throws -> [Transaction] {
        try ctx.fetch(FetchDescriptor<Transaction>())
    }

    /// The canonical fixture: 10 000 RON @ 12% nominal (1%/mo) over 12 months. The
    /// first three splits (verified in `AmortizationScheduleTests`):
    ///   row 0 → interest 100.00, principal 788.49
    ///   row 1 → interest  92.12, principal 796.37
    ///   row 2 → interest  84.15, principal 804.34
    private func standardLoan(_ start: Date, projectID: UUID? = UUID()) -> Loan {
        Loan(name: "Credit", lender: "BCR", kind: .bank, principal: 10_000,
             currency: .ron, annualRatePercent: dec("12"), startDate: start,
             termMonths: 12, projectID: projectID)
    }

    // MARK: - M1: double-tap markDone books exactly one transaction

    func testDoubleTapMarkDoneBooksExactlyOneTransaction() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()

        // A plain, NON-loan outgoing item (loanID == nil, no recurrence).
        let item = ScheduledItem(direction: .outgoing, amount: 1500, currency: .ron,
                                 title: "Furnizor", counterparty: "Dedeman",
                                 dueDate: cal.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 9))!)
        ctx.insert(item)
        try ctx.save()

        let first = ScheduledItemStore.markDone(item, calendar: cal, in: ctx)
        XCTAssertEqual(try transactions(ctx).count, 1, "first mark-done books one transaction")
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(item.linkedTransactionID, first.id)

        // Second tap on the now-done item: books NOTHING and returns the same tx.
        let again = ScheduledItemStore.markDone(item, calendar: cal, in: ctx)
        XCTAssertEqual(try transactions(ctx).count, 1, "double-tap must NOT book a second transaction")
        XCTAssertEqual(again.id, first.id, "re-entry returns the existing linked transaction")
        XCTAssertEqual(item.linkedTransactionID, first.id, "the first transaction is never orphaned")
    }

    // MARK: - M3: out-of-order booking books each row's EXACT split

    func testOutOfOrderBookingBooksEachRowsExactSplit() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
        let loan = standardLoan(start)

        // Items come back in schedule order; item[k].scheduleIndex == k.
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }
        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(items.map { $0.scheduleIndex }, Array(0..<12), "every payment is stamped with its row index")

        // Book rows 2, 0, 1 — deliberately out of order. Each must still get its own
        // exact split, bound by stamp, not by booking sequence.
        let booked2 = try XCTUnwrap(LoanStore.bookPayment(items[2], loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked2.interest.amount, dec("84.15"), "row 2 interest")
        XCTAssertEqual(booked2.principal.amount, dec("804.34"), "row 2 principal")

        let booked0 = try XCTUnwrap(LoanStore.bookPayment(items[0], loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked0.interest.amount, dec("100.00"), "row 0 interest")
        XCTAssertEqual(booked0.principal.amount, dec("788.49"), "row 0 principal")

        let booked1 = try XCTUnwrap(LoanStore.bookPayment(items[1], loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked1.interest.amount, dec("92.12"), "row 1 interest")
        XCTAssertEqual(booked1.principal.amount, dec("796.37"), "row 1 principal")
    }

    // MARK: - M3: loan edit after a partial payment → subsequent booking still exact

    func testLoanEditAfterPartialPaymentBooksSubsequentRowExactly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        // Start LATE so that, after editing to an EARLIER start, the still-done
        // item's original due date sorts AFTER the regenerated pending items — the
        // exact interleave that breaks a sorted-position binding.
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
        let loan = standardLoan(start)
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }

        // Book the first payment (row 0).
        _ = try XCTUnwrap(LoanStore.bookPayment(items[0], loan: loan, calendar: cal, in: ctx))

        // Edit the loan: shift the start earlier, then re-sync pending payments
        // (exactly what LoanEditSheet does). The split values are start-independent,
        // so row 1 is still 92.12 / 796.37 — only the due dates move.
        loan.startDate = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
        LoanStore.syncPendingPayment(for: loan, calendar: cal, in: ctx)

        // The next payment the user books = earliest-due pending item. After the
        // edit that is the regenerated row-1 item, whose ORIGINAL sorted position is
        // now 0 (it precedes the done row-0 item). A stamp binds it to row 1.
        let nextPending = try XCTUnwrap((try ctx.fetch(FetchDescriptor<ScheduledItem>()))
            .filter { $0.loanID == loan.id && $0.status == .pending }
            .min { $0.dueDate < $1.dueDate })
        XCTAssertEqual(nextPending.scheduleIndex, 1, "the regenerated next item still carries its true row stamp")

        let booked = try XCTUnwrap(LoanStore.bookPayment(nextPending, loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked.interest.amount, dec("92.12"), "binds to row 1 by stamp, not to row 0 by sorted position")
        XCTAssertNotEqual(booked.interest.amount, dec("100.00"), "a sorted-position binding would have mis-booked row 0")
        XCTAssertEqual(booked.principal.amount, dec("796.37"))
    }

    // MARK: - M3: legacy unstamped pending items fall back to due-date order

    func testLegacyUnstampedItemsFallBackToDueDateOrder() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
        let loan = standardLoan(start)
        ctx.insert(loan)
        LoanCategories.seedInterestCategory(in: ctx)

        // Reproduce a PRE-STAMP series: loan-tagged pending items with NO stamp
        // (scheduleIndex defaults to nil, exactly what a migrated legacy row reads).
        let schedule = loan.schedule(calendar: cal)
        let seriesID = UUID()
        for row in schedule {
            ctx.insert(ScheduledItem(direction: .outgoing, amount: row.payment, currency: .ron,
                                     title: loan.name, counterparty: loan.lender, dueDate: row.dueDate,
                                     projectID: loan.projectID, status: .pending, recurrence: .none,
                                     seriesID: seriesID, loanID: loan.id))   // no scheduleIndex
        }
        try ctx.save()

        let items = (try ctx.fetch(FetchDescriptor<ScheduledItem>()))
            .filter { $0.loanID == loan.id }.sorted { $0.dueDate < $1.dueDate }
        XCTAssertNil(items[0].scheduleIndex, "legacy items have no stamp (nil), as a migrated row would")

        // Booking still resolves the right split via the due-date-order fallback.
        let booked0 = try XCTUnwrap(LoanStore.bookPayment(items[0], loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked0.interest.amount, dec("100.00"), "row 0 via fallback ordinal")
        XCTAssertEqual(booked0.principal.amount, dec("788.49"))

        let booked1 = try XCTUnwrap(LoanStore.bookPayment(items[1], loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked1.interest.amount, dec("92.12"), "row 1 via fallback ordinal")
        XCTAssertEqual(booked1.principal.amount, dec("796.37"))
    }

    // MARK: - M5(a): below-interest fixed payment rejected at create/edit

    func testBelowInterestFixedPaymentRejectedAtCreate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!

        // 10 000 @ 12% ⇒ first-period interest = 100. A fixed payment of 100 (equal)
        // or below can never amortize.
        XCTAssertFalse(AmortizationSchedule.canAmortize(principal: 10_000, annualRatePercent: dec("12"), fixedMonthlyPayment: dec("100")))
        XCTAssertFalse(AmortizationSchedule.canAmortize(principal: 10_000, annualRatePercent: dec("12"), fixedMonthlyPayment: dec("90")))
        // A payment above the first-period interest is fine; so is the annuity path.
        XCTAssertTrue(AmortizationSchedule.canAmortize(principal: 10_000, annualRatePercent: dec("12"), fixedMonthlyPayment: dec("900")))
        XCTAssertTrue(AmortizationSchedule.canAmortize(principal: 10_000, annualRatePercent: dec("12"), fixedMonthlyPayment: nil))

        // The throwing validator the create/edit call sites use.
        XCTAssertThrowsError(try LoanStore.validate(principal: 10_000, annualRatePercent: dec("12"), fixedMonthlyPayment: dec("100"))) { error in
            XCTAssertEqual(error as? LoanStore.ValidationError, .fixedPaymentBelowInterest)
        }
        XCTAssertNoThrow(try LoanStore.validate(principal: 10_000, annualRatePercent: dec("12"), fixedMonthlyPayment: dec("900")))

        // createLoan REFUSES to persist a non-amortizing loan.
        let bad = Loan(name: "Rău", lender: "X", kind: .bank, principal: 10_000, currency: .ron,
                       annualRatePercent: dec("12"), startDate: start, termMonths: nil, fixedMonthlyPayment: dec("100"))
        let items = LoanStore.createLoan(bad, calendar: cal, in: ctx)
        XCTAssertTrue(items.isEmpty, "no payment series is generated for a non-amortizing loan")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Loan>()), 0, "the loan is never persisted")

        // A valid loan is created normally.
        let good = Loan(name: "Bun", lender: "X", kind: .bank, principal: 10_000, currency: .ron,
                        annualRatePercent: dec("12"), startDate: start, termMonths: 12, fixedMonthlyPayment: dec("900"))
        XCTAssertFalse(LoanStore.createLoan(good, calendar: cal, in: ctx).isEmpty)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Loan>()), 1)
    }

    // MARK: - M5(b): legacy truncated schedule sets the flag; interest not silent

    func testLegacyTruncatedScheduleFlagsCostOfCapital() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!

        // The pure schedule collapses AND flags a below-interest fixed payment.
        let result = AmortizationSchedule.scheduleResult(
            principal: 10_000, annualRatePercent: dec("12"), termMonths: nil,
            startDate: start, fixedMonthlyPayment: dec("100"), calendar: cal
        )
        XCTAssertEqual(result.rows.count, 1, "the degenerate loan collapses to a single row")
        XCTAssertTrue(result.isTruncated, "the collapse is flagged, never silent")
        XCTAssertEqual(AmortizationSchedule.totalInterest(result.rows), dec("100.00"),
                       "the reported interest is only a one-month FLOOR")

        // A LEGACY stored loan (persisted directly, before validation existed) must
        // surface the flag through the Raport model so cost-of-capital is not
        // silently understated.
        let legacy = Loan(name: "Vechi", lender: "Y", kind: .investor, principal: 10_000, currency: .ron,
                          annualRatePercent: dec("12"), startDate: start, termMonths: nil, fixedMonthlyPayment: dec("100"))
        ctx.insert(legacy)
        try ctx.save()

        let model = RaportHubBuilder.build(
            lines: [], loans: [legacy.snapshot], projects: [], items: [],
            rate: nil, horizon: .days30,
            cashflowInterval: DateInterval(start: .distantPast, end: .distantFuture),
            calendar: cal
        )
        let row = try XCTUnwrap(model.investorDebt.rows.first)
        XCTAssertEqual(row.totalInterest, dec("100.00"))
        XCTAssertTrue(row.totalInterestTruncated, "the row flags its interest as a truncated floor")
        XCTAssertTrue(model.investorDebt.costOfCapitalTruncated, "the section flags its cost-of-capital as understated")
    }

    // MARK: - M4: next-payment preview == the row bookPayment will book (out-of-order)

    func testNextPaymentPreviewMatchesBookPaymentEvenOutOfOrder() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
        let loan = standardLoan(start)
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }

        // Book row 1 OUT OF ORDER (the second payment first). Row 0 stays pending, so
        // the true "next" payment is still row 0 — but one neutral slice is now booked.
        _ = try XCTUnwrap(LoanStore.bookPayment(items[1], loan: loan, calendar: cal, in: ctx))

        func build(withStampMap: Bool) throws -> RaportHubModel {
            let txLines = try transactions(ctx).map {
                RaportTxLine(amount: $0.amount, currency: $0.currency, direction: $0.direction,
                             projectID: $0.projectID, loanID: $0.loanID, date: $0.date)
            }
            var map: [UUID: Int] = [:]
            if withStampMap {
                let pendingStamps = (try ctx.fetch(FetchDescriptor<ScheduledItem>()))
                    .filter { $0.loanID == loan.id && $0.status == .pending }
                    .compactMap { $0.scheduleIndex }
                map = RaportHubBuilder.nextLoanPaymentIndex(pendingStampsByLoan: [loan.id: pendingStamps])
            }
            return RaportHubBuilder.build(
                lines: txLines, loans: [loan.snapshot], projects: [], items: [],
                rate: nil, horizon: .days30,
                cashflowInterval: DateInterval(start: .distantPast, end: .distantFuture),
                nextLoanPaymentIndex: map, calendar: cal
            )
        }

        // WITH the stamp map: preview is row 0 (100.00 / 788.49) — the lowest-stamped
        // pending item, exactly what bookPayment will book next.
        let previewed = try XCTUnwrap(try build(withStampMap: true).bankDebt.rows.first)
        XCTAssertEqual(previewed.nextInterest, dec("100.00"), "preview = lowest-stamped pending row (row 0)")
        XCTAssertEqual(previewed.nextPrincipal, dec("788.49"))
        XCTAssertEqual(previewed.nextPayment, dec("888.49"))
        XCTAssertEqual(previewed.nextDueDate, items[0].dueDate)

        // WITHOUT the map, the booked-count fallback wrongly previews row 1 (the row
        // already booked) — the bug the stamp map fixes.
        let buggy = try XCTUnwrap(try build(withStampMap: false).bankDebt.rows.first)
        XCTAssertEqual(buggy.nextInterest, dec("92.12"), "booked-count ordering mis-previews the already-booked row 1")

        // And the preview truly equals what bookPayment books: book the next pending
        // (earliest due = row 0) and confirm the split matches the preview.
        let nextPending = try XCTUnwrap((try ctx.fetch(FetchDescriptor<ScheduledItem>()))
            .filter { $0.loanID == loan.id && $0.status == .pending }
            .min { $0.dueDate < $1.dueDate })
        let booked = try XCTUnwrap(LoanStore.bookPayment(nextPending, loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(booked.interest.amount, previewed.nextInterest, "preview matched the actual booking")
        XCTAssertEqual(booked.principal.amount, previewed.nextPrincipal)
    }
}
