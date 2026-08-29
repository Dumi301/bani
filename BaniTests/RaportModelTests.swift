import XCTest
import SwiftData
@testable import Bani

/// P7 gate — the Raport hub's section view-models against a seeded in-memory
/// container. Proves: liquidity honors loans (loan payments already counted once
/// via their `ScheduledItem`s) and anchors (a reconcile adjustment is a real flow,
/// so `netLoggedPosition` moves with it); receivables totals; bank-vs-investor
/// separation with the load-bearing invariant that **investor interest never enters
/// any project rollup**; and the project budgeting math (paid / due / %).
@MainActor
final class RaportModelTests: XCTestCase {

    // MARK: - Fixtures

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, ScheduledItem.self, Project.self, Loan.self,
            CustomCategory.self, BalanceAnchor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Fetch everything and assemble the hub model exactly as the view does.
    private func buildModel(
        in ctx: ModelContext,
        rate: Decimal? = nil,
        horizon: LiquidityHorizon = .days30,
        now: Date = .now,
        calendar: Calendar = .current,
        cashflow: DateInterval = DateInterval(start: .distantPast, end: .distantFuture)
    ) -> RaportHubModel {
        let transactions = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        let loans = (try? ctx.fetch(FetchDescriptor<Loan>())) ?? []
        let projects = (try? ctx.fetch(FetchDescriptor<Project>())) ?? []
        let items = (try? ctx.fetch(FetchDescriptor<ScheduledItem>())) ?? []
        return RaportHubBuilder.build(
            lines: transactions.map {
                RaportTxLine(amount: $0.amount, currency: $0.currency, direction: $0.direction,
                             projectID: $0.projectID, loanID: $0.loanID, date: $0.date)
            },
            loans: loans.map(\.snapshot),
            projects: projects.map(\.snapshot),
            items: items.map(\.snapshot),
            rate: rate,
            horizon: horizon,
            cashflowInterval: cashflow,
            loanItemIDs: Set(items.filter { $0.loanID != nil }.map(\.id)),
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Position: liquidity honors loans

    func testLiquidityHonorsLoansAndCashflow() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2025, month: 12, day: 20, hour: 9))!

        // Plain flows: +5000 income, −1000 expense ⇒ netLoggedPosition = 4000.
        ctx.insert(Transaction(amount: 5000, currency: .ron, context: .work,
                               descriptionText: "încasare", date: now, source: .manual, direction: .income))
        ctx.insert(Transaction(amount: 1000, currency: .ron, context: .work,
                               descriptionText: "cheltuială", date: now, source: .manual, direction: .expense))
        try ctx.save()

        // 12 000 RON, interest-free, 12 monthly payments of 1000 on the 20th; from
        // now (Jan 10) the 30-day horizon lands on exactly ONE payment (Jan 20).
        let loan = Loan(name: "Credit", lender: "BCR", kind: .bank, principal: 12_000,
                        currency: .ron, annualRatePercent: nil, startDate: start,
                        termMonths: 12, projectID: nil)
        LoanStore.createLoan(loan, calendar: cal, in: ctx)

        let model = buildModel(in: ctx, horizon: .days30, now: now, calendar: cal)

        XCTAssertEqual(model.position.netLoggedPosition, 4000)
        // One loan payment is expected out over 30 days; nothing expected in.
        XCTAssertEqual(model.position.liquidity.expectedOut, 1000)
        XCTAssertEqual(model.position.liquidity.expectedIn, 0)
        // freeLiquidity = net + expectedIn − expectedOut = 4000 − 1000 = 3000.
        XCTAssertEqual(model.position.liquidity.freeLiquidity, 3000)
        // Cash flow over the (all-time) window: 5000 in, 1000 out.
        XCTAssertEqual(model.position.cashIn, 5000)
        XCTAssertEqual(model.position.cashOut, 1000)
        XCTAssertEqual(model.position.cashNet, 4000)

        // Debt section: one bank loan, full principal outstanding, next payment 1000.
        XCTAssertEqual(model.bankDebt.rows.count, 1)
        let row = try XCTUnwrap(model.bankDebt.rows.first)
        XCTAssertEqual(row.outstanding, 12_000)
        XCTAssertEqual(row.percentLeft, 100)
        XCTAssertEqual(row.nextPayment, 1000)

        // Book the first payment: outstanding drops by exactly its principal (1000);
        // netLoggedPosition is unchanged (interest-free ⇒ 0 expense; principal is neutral).
        let pending = (try ctx.fetch(FetchDescriptor<ScheduledItem>()))
            .filter { $0.loanID == loan.id && $0.status == .pending }
            .sorted { $0.dueDate < $1.dueDate }
        LoanStore.bookPayment(try XCTUnwrap(pending.first), loan: loan, date: now, calendar: cal, in: ctx)

        let after = buildModel(in: ctx, horizon: .days30, now: now, calendar: cal)
        XCTAssertEqual(after.bankDebt.rows.first?.outstanding, 11_000)
        XCTAssertEqual(after.position.netLoggedPosition, 4000)
    }

    // MARK: - Position: anchor-aware

    func testPositionHonorsBalanceAnchorAdjustment() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        // Logged position from flows alone = +2000 − 500 = 1500.
        ctx.insert(Transaction(amount: 2000, currency: .ron, context: .personal,
                               descriptionText: "in", source: .manual, direction: .income))
        ctx.insert(Transaction(amount: 500, currency: .ron, context: .personal,
                               descriptionText: "out", source: .manual, direction: .expense))
        try ctx.save()

        XCTAssertEqual(buildModel(in: ctx).position.netLoggedPosition, 1500)

        // Client's real balance is 2000 (200 more than logged): commit the closing
        // adjustment. netLoggedPosition must now equal the anchored reality.
        let result = ReconciliationStore.result(actual: 2000, currency: .ron, in: ctx)
        XCTAssertEqual(result.drift, 500)  // 2000 actual − 1500 expected
        ReconciliationStore.createAdjustmentAndAnchor(result: result, in: ctx)

        XCTAssertEqual(buildModel(in: ctx).position.netLoggedPosition, 2000)
    }

    // MARK: - Receivables

    func testReceivablesTotalsAndTopPeople() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = Date()

        ctx.insert(ScheduledItem(direction: .incoming, amount: 1000, currency: .ron,
                                 title: "Chirie", counterparty: "Ana", dueDate: now.addingTimeInterval(86_400)))
        ctx.insert(ScheduledItem(direction: .incoming, amount: 500, currency: .ron,
                                 title: "Împrumut", counterparty: "Bogdan", dueDate: now.addingTimeInterval(2 * 86_400)))
        // An OUTGOING pending item is money the client owes — never a receivable.
        ctx.insert(ScheduledItem(direction: .outgoing, amount: 9999, currency: .ron,
                                 title: "Furnizor", counterparty: "Firma", dueDate: now))
        try ctx.save()

        let model = buildModel(in: ctx, rate: 4.9)
        XCTAssertEqual(model.receivables.grandTotal, 1500)
        XCTAssertEqual(model.receivables.people.count, 2)
        XCTAssertEqual(model.receivables.people.first?.counterparty, "Ana")   // sorted by total desc
    }

    // MARK: - Bank vs investor separation

    func testInvestorInterestNeverEntersAnyProjectRollup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9))!

        let project = Project(name: "Bloc A", colorIndex: 2)
        ctx.insert(project)

        // Bank loan on the project: 12 000 @ 12%/yr ⇒ first-payment interest = 120.
        let bank = Loan(name: "Credit bancă", lender: "BCR", kind: .bank, principal: 12_000,
                        currency: .ron, annualRatePercent: 12, startDate: start,
                        termMonths: 12, projectID: project.id)
        LoanStore.createLoan(bank, calendar: cal, in: ctx)

        // Investor money: 10 000 @ 24%/yr ⇒ first-payment interest = 200, project nil.
        let investor = Loan(name: "Investitor X", lender: "PersonA", kind: .investor, principal: 10_000,
                            currency: .ron, annualRatePercent: 24, startDate: start,
                            termMonths: 10, projectID: nil)
        LoanStore.createLoan(investor, calendar: cal, in: ctx)

        func firstPending(_ loan: Loan) throws -> ScheduledItem {
            try XCTUnwrap((try ctx.fetch(FetchDescriptor<ScheduledItem>()))
                .filter { $0.loanID == loan.id && $0.status == .pending }
                .min { $0.dueDate < $1.dueDate })
        }
        LoanStore.bookPayment(try firstPending(bank), loan: bank, date: now, calendar: cal, in: ctx)
        LoanStore.bookPayment(try firstPending(investor), loan: investor, date: now, calendar: cal, in: ctx)

        let model = buildModel(in: ctx, horizon: .days30, now: now, calendar: cal)

        // The project's invested = ONLY the bank interest (120). The investor
        // interest (200) is booked with projectID == nil and must not appear.
        let projectRow = try XCTUnwrap(model.projects.first { $0.projectID == project.id })
        XCTAssertEqual(projectRow.invested, 120)
        XCTAssertEqual(model.projects.reduce(Decimal(0)) { $0 + $1.invested }, 120,
                       "no project rollup may include investor interest")

        // Tx-level invariant: the investor interest transaction carries no project.
        let investorInterest = try XCTUnwrap((try ctx.fetch(FetchDescriptor<Transaction>()))
            .first { $0.loanID == investor.id && $0.direction == .expense })
        XCTAssertEqual(investorInterest.amount, 200)
        XCTAssertNil(investorInterest.projectID)

        // The investor debt section carries a non-zero cost-of-capital line.
        XCTAssertEqual(model.bankDebt.rows.count, 1)
        XCTAssertEqual(model.investorDebt.rows.count, 1)
        XCTAssertGreaterThan(model.investorDebt.costOfCapital, 0)
        // The bank row names the project its interest books to.
        XCTAssertEqual(model.bankDebt.rows.first?.bookedToProjectID, project.id)
        XCTAssertEqual(model.bankDebt.rows.first?.bookedToProjectName, "Bloc A")
    }

    // MARK: - Project budgeting math

    func testProjectBudgetingRowsMath() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let now = Date()

        let project = Project(name: "Renovare", colorIndex: 4)
        ctx.insert(project)
        // One paid (done) and one pending outgoing commitment ⇒ paid 2000, due 3000,
        // 40% paid, next due = the pending item's date.
        ctx.insert(ScheduledItem(direction: .outgoing, amount: 2000, currency: .ron,
                                 title: "Avans", dueDate: now.addingTimeInterval(-86_400),
                                 projectID: project.id, status: .done))
        let nextDue = now.addingTimeInterval(5 * 86_400)
        ctx.insert(ScheduledItem(direction: .outgoing, amount: 3000, currency: .ron,
                                 title: "Tranșă", dueDate: nextDue,
                                 projectID: project.id, status: .pending))
        // An INCOMING item is not a budgeting outflow — excluded from paid/due.
        ctx.insert(ScheduledItem(direction: .incoming, amount: 8000, currency: .ron,
                                 title: "Client", dueDate: nextDue, projectID: project.id))
        try ctx.save()

        let row = try XCTUnwrap(buildModel(in: ctx).projects.first { $0.projectID == project.id })
        XCTAssertEqual(row.paid, 2000)
        XCTAssertEqual(row.due, 3000)
        XCTAssertEqual(row.percentPaid, 40)
        XCTAssertEqual(row.nextDueDate, nextDue)
    }
}
