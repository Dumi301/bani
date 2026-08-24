import XCTest
import SwiftData
@testable import Bani

/// v1.2b "Loans" — proves the mark-done ROUTING: completing a loan-linked
/// `ScheduledItem` through the generic `ScheduledItemStore.markDone` delegates to
/// `LoanStore.bookPayment` (the two-transaction interest/principal split), is
/// idempotent, and never fires the P2 recurrence hook. A companion test proves an
/// ordinary recurring item's mark-done behaviour is UNCHANGED (guards P2).
@MainActor
final class LoanMarkDoneDelegationTests: XCTestCase {

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

    private func bankLoan(projectID: UUID) -> Loan {
        Loan(name: "Credit", lender: "BCR", kind: .bank, principal: 10_000,
             currency: .ron, annualRatePercent: dec("12"), startDate: Date(),
             termMonths: 12, projectID: projectID)
    }

    private func loanTransactions(_ loan: Loan, in ctx: ModelContext) throws -> [Transaction] {
        try ctx.fetch(FetchDescriptor<Transaction>()).filter { $0.loanID == loan.id }
    }

    // MARK: - Delegation equivalence

    /// markDone on a loan item produces the SAME split as calling
    /// LoanStore.bookPayment directly: two loans, identical terms — one completed
    /// through markDone, one through bookPayment — yield matching interest and
    /// principal transactions.
    func testMarkDoneOnLoanItemMatchesBookPaymentSplit() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let pid = UUID()

        let loanA = bankLoan(projectID: pid)
        let loanB = bankLoan(projectID: pid)
        let itemsA = LoanStore.createLoan(loanA, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }
        let itemsB = LoanStore.createLoan(loanB, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }

        // Path A: the generic mark-done — must delegate to the split path.
        let returnedA = ScheduledItemStore.markDone(itemsA[0], calendar: cal, in: ctx)
        // Path B: the split path directly.
        let bookedB = try XCTUnwrap(LoanStore.bookPayment(itemsB[0], loan: loanB, calendar: cal, in: ctx))

        let txA = try loanTransactions(loanA, in: ctx)
        XCTAssertEqual(txA.count, 2, "markDone on a loan item books EXACTLY two transactions (the split)")
        let interestA = try XCTUnwrap(txA.first { $0.direction == .expense })
        let principalA = try XCTUnwrap(txA.first { $0.direction == .neutral })

        // markDone returns the interest transaction (the linked one).
        XCTAssertEqual(returnedA.id, interestA.id, "markDone returns the interest transaction")
        XCTAssertEqual(itemsA[0].linkedTransactionID, interestA.id)
        XCTAssertEqual(itemsA[0].status, .done)

        // Interest slice matches bookPayment: amount, direction, project, category, loan.
        XCTAssertEqual(interestA.amount, bookedB.interest.amount)
        XCTAssertEqual(interestA.amount, dec("100.00"))
        XCTAssertEqual(interestA.direction, .expense)
        XCTAssertEqual(interestA.projectID, pid)
        XCTAssertEqual(interestA.projectID, bookedB.interest.projectID)
        XCTAssertEqual(interestA.customCategoryID, LoanCategories.interestCategoryID)
        XCTAssertEqual(interestA.customCategoryID, bookedB.interest.customCategoryID)
        XCTAssertEqual(interestA.loanID, loanA.id)

        // Principal slice matches bookPayment: amount, neutral, no project.
        XCTAssertEqual(principalA.amount, bookedB.principal.amount)
        XCTAssertEqual(principalA.amount, dec("788.49"))
        XCTAssertEqual(principalA.direction, .neutral)
        XCTAssertNil(principalA.projectID)
        XCTAssertEqual(principalA.loanID, loanA.id)
    }

    // MARK: - No recurrence duplicate

    /// The P2 recurrence hook must NOT fire for a loan item: the loan's full series
    /// is pre-generated, so marking one done adds NO extra occurrence.
    func testMarkDoneOnLoanItemGeneratesNoRecurrenceDuplicate() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()

        let loan = bankLoan(projectID: UUID())
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }
        XCTAssertEqual(items.count, 12)

        ScheduledItemStore.markDone(items[0], calendar: cal, in: ctx)

        let all = try ctx.fetch(FetchDescriptor<ScheduledItem>()).filter { $0.loanID == loan.id }
        XCTAssertEqual(all.count, 12, "no 13th item — the series is pre-generated, recurrence never fired")
        XCTAssertEqual(all.filter { $0.status == .done }.count, 1)
        XCTAssertEqual(all.filter { $0.status == .pending }.count, 11)
    }

    // MARK: - Idempotence through markDone

    /// Marking the same (now done) loan item done again books nothing and returns
    /// its existing linked transaction.
    func testMarkDoneOnLoanItemIsIdempotent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()

        let loan = bankLoan(projectID: UUID())
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }

        let first = ScheduledItemStore.markDone(items[0], calendar: cal, in: ctx)
        XCTAssertEqual(try loanTransactions(loan, in: ctx).count, 2)

        let again = ScheduledItemStore.markDone(items[0], calendar: cal, in: ctx)
        XCTAssertEqual(try loanTransactions(loan, in: ctx).count, 2, "no second booking on re-entry")
        XCTAssertEqual(again.id, first.id, "re-entry returns the same linked interest transaction")
    }

    // MARK: - P2 guard: ordinary recurring item is UNCHANGED

    /// A NON-loan recurring item still takes the generic single-transaction flow
    /// AND spawns its next occurrence — the P2 behaviour is untouched by the loan
    /// routing.
    func testMarkDoneOnNonLoanRecurringItemStillGeneratesNextOccurrence() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let due = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let item = ScheduledItem(direction: .outgoing, amount: 3500, currency: .ron, title: "Chirie",
                                 dueDate: due, recurrence: .monthly)   // loanID == nil
        ctx.insert(item)
        try ctx.save()

        let tx = ScheduledItemStore.markDone(item, calendar: cal, in: ctx)

        // Generic single transaction (NOT a split): exactly one, direction expense,
        // no loanID.
        let all = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(all.count, 1, "a non-loan item books exactly one generic transaction")
        XCTAssertEqual(tx.direction, .expense)
        XCTAssertNil(tx.loanID)

        // P2 recurrence still fires: one next pending occurrence, same series.
        XCTAssertEqual(item.status, .done)
        XCTAssertNotNil(item.seriesID)
        let items = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        XCTAssertEqual(items.count, 2, "origin + one next occurrence (P2 unchanged)")
        let next = try XCTUnwrap(items.first { $0.status == .pending })
        XCTAssertEqual(next.seriesID, item.seriesID)
        XCTAssertEqual(next.dueDate, cal.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 9))!)
    }
}
