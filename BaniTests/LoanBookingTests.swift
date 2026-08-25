import XCTest
import SwiftData
@testable import Bani

/// v1.2b "Loans" — booking a loan payment produces the two split transactions with
/// the correct accounting: a bank loan's interest slice is a project expense; an
/// investor loan's interest is cost-of-capital with NO project; the principal slice
/// is always a neutral balance movement. Booking is idempotent (no double booking),
/// and the final payment closes the loan.
@MainActor
final class LoanBookingTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    /// Returns the container (NOT just its context) so the caller retains it for the
    /// test's lifetime — mirrors `ScheduledItemLifecycleTests.makeContainer`.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, ScheduledItem.self, Project.self, Loan.self, CustomCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func transactions(_ ctx: ModelContext) throws -> [Transaction] {
        try ctx.fetch(FetchDescriptor<Transaction>())
    }

    // MARK: - Bank payment → two transactions, interest carries project + category

    func testBankPaymentBooksInterestExpenseAgainstProjectAndNeutralPrincipal() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let projectID = UUID()
        let loan = Loan(name: "Credit BCR", lender: "BCR", kind: .bank, principal: 10_000,
                        currency: .ron, annualRatePercent: dec("12"), startDate: Date(),
                        termMonths: 12, projectID: projectID)

        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx)
        XCTAssertEqual(items.count, 12, "the full monthly series is generated up front")

        // The loan-interest category was seeded exactly once.
        let seedID = LoanCategories.interestCategoryID
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<CustomCategory>(predicate: #Predicate { $0.id == seedID })), 1)

        let first = try XCTUnwrap(items.sorted { $0.dueDate < $1.dueDate }.first)
        let booked = try XCTUnwrap(LoanStore.bookPayment(first, loan: loan, calendar: cal, in: ctx))

        // Exactly two transactions were written.
        XCTAssertEqual(try transactions(ctx).count, 2, "a loan payment books exactly two transactions")

        // Interest slice: expense, the loan's project, the loan-interest category, loanID.
        XCTAssertEqual(booked.interest.direction, .expense)
        XCTAssertEqual(booked.interest.amount, dec("100.00"), "first interest = 10000 × 0.01")
        XCTAssertEqual(booked.interest.projectID, projectID, "bank interest is a project expense")
        XCTAssertEqual(booked.interest.customCategoryID, LoanCategories.interestCategoryID, "interest carries the loan-interest category")
        XCTAssertEqual(booked.interest.loanID, loan.id)
        XCTAssertEqual(booked.interest.counterparty, "BCR")

        // Principal slice: neutral, NO project, loanID.
        XCTAssertEqual(booked.principal.direction, .neutral, "principal is a neutral balance movement, never an expense")
        XCTAssertEqual(booked.principal.amount, dec("788.49"), "principal = payment − interest = 888.49 − 100")
        XCTAssertNil(booked.principal.projectID, "principal never lands in any project P&L")
        XCTAssertEqual(booked.principal.loanID, loan.id)

        // The item is done and linked; a next pending payment remains in the series.
        XCTAssertEqual(first.status, .done)
        XCTAssertEqual(first.linkedTransactionID, booked.interest.id)
        let pending = try ctx.fetch(FetchDescriptor<ScheduledItem>()).filter { $0.status == .pending }
        XCTAssertEqual(pending.count, 11, "the other 11 payments are still pending")
    }

    // MARK: - Investor payment → interest has NO project (cost-of-capital)

    func testInvestorPaymentInterestHasNilProjectEvenIfLoanHasProject() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        // Deliberately set a project on the investor loan to prove the KIND gate
        // (not a missing project) forces the interest off every project rollup.
        let loan = Loan(name: "Împrumut Andrei", lender: "Andrei", kind: .investor, principal: 5_000,
                        currency: .ron, annualRatePercent: dec("10"), startDate: Date(),
                        termMonths: 10, projectID: UUID())

        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx)
        let first = try XCTUnwrap(items.sorted { $0.dueDate < $1.dueDate }.first)
        let booked = try XCTUnwrap(LoanStore.bookPayment(first, loan: loan, calendar: cal, in: ctx))

        XCTAssertEqual(booked.interest.direction, .expense)
        XCTAssertNil(booked.interest.projectID, "investor interest is cost-of-capital: NEVER in a project P&L")
        XCTAssertEqual(booked.interest.customCategoryID, LoanCategories.interestCategoryID)
        XCTAssertEqual(booked.interest.loanID, loan.id)
        XCTAssertEqual(booked.principal.direction, .neutral)
        XCTAssertNil(booked.principal.projectID)
    }

    // MARK: - Idempotence (no double booking)

    func testBookingSamePaymentTwiceDoesNotDoubleBook() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let loan = Loan(name: "Credit", lender: "ING", kind: .bank, principal: 10_000,
                        currency: .ron, annualRatePercent: dec("12"), startDate: Date(),
                        termMonths: 12, projectID: UUID())
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx)
        let first = try XCTUnwrap(items.sorted { $0.dueDate < $1.dueDate }.first)

        XCTAssertNotNil(LoanStore.bookPayment(first, loan: loan, calendar: cal, in: ctx))
        XCTAssertEqual(try transactions(ctx).count, 2)

        // Second call on the same (now done) item books nothing.
        XCTAssertNil(LoanStore.bookPayment(first, loan: loan, calendar: cal, in: ctx),
                     "a done item never books again")
        XCTAssertEqual(try transactions(ctx).count, 2, "still exactly two transactions — no double booking")
    }

    // MARK: - Full repayment closes the loan; position derives sum-owed / % left

    func testBookingEveryPaymentClosesLoanAndZeroesOutstanding() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let loan = Loan(name: "Avans 0%", lender: "Partener", kind: .investor, principal: 100,
                        currency: .ron, annualRatePercent: nil, startDate: Date(), termMonths: 2)
        let items = LoanStore.createLoan(loan, calendar: cal, in: ctx).sorted { $0.dueDate < $1.dueDate }
        XCTAssertEqual(items.count, 2)

        // Halfway: one payment booked, half outstanding.
        _ = LoanStore.bookPayment(items[0], loan: loan, calendar: cal, in: ctx)
        var pos = LoanStore.position(for: loan, in: ctx)
        XCTAssertEqual(pos.outstanding, 50)
        XCTAssertEqual(pos.percentLeft, 50)
        XCTAssertEqual(loan.status, .active, "not yet fully repaid")

        // Final payment: loan closes, nothing owed, no pending items.
        _ = LoanStore.bookPayment(items[1], loan: loan, calendar: cal, in: ctx)
        pos = LoanStore.position(for: loan, in: ctx)
        XCTAssertEqual(pos.outstanding, 0)
        XCTAssertEqual(pos.percentLeft, 0)
        XCTAssertEqual(loan.status, .closed, "booking the final payment closes the loan")
        let pending = try ctx.fetch(FetchDescriptor<ScheduledItem>()).filter { $0.status == .pending }
        XCTAssertTrue(pending.isEmpty)
    }
}
