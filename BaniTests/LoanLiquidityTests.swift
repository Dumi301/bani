import XCTest
import SwiftData
@testable import Bani

/// v1.2b "Loans" — THE no-double-count proof. Loan payments are ordinary outgoing
/// `ScheduledItem`s, so the 30/60/90 liquidity horizons already see each payment
/// that falls in the window — exactly once — through `expectedOut`. The
/// `loanAdjustment` seam therefore stays `.zero` in production: injecting the
/// loan's outstanding balance on TOP of the payment items would count the debt
/// twice. This test pins both halves of that decision.
@MainActor
final class LoanLiquidityTests: XCTestCase {

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

    /// A loan whose 12 monthly payments of 1000 RON fall on the 20th, starting
    /// 2025-12-20, so that from a fixed "now" of 2026-01-10 the horizons land on
    /// exactly 1 / 2 / 3 payments (30d → Jan 20; 60d → +Feb 20; 90d → +Mar 20).
    func testHorizonsCountEachLoanPaymentExactlyOnceAndSeamStaysZero() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2025, month: 12, day: 20, hour: 9))!

        // 12 000 RON, interest-free, 12 months ⇒ 12 payments of 1000 (clean money).
        let loan = Loan(name: "Credit", lender: "BCR", kind: .bank, principal: 12_000,
                        currency: .ron, annualRatePercent: nil, startDate: start,
                        termMonths: 12, projectID: UUID())
        _ = LoanStore.createLoan(loan, calendar: cal, in: ctx)

        let pending = try ctx.fetch(FetchDescriptor<ScheduledItem>())
            .filter { $0.status == .pending }
            .map(\.snapshot)
        XCTAssertEqual(pending.count, 12)

        let net: Decimal = 50_000

        for (horizon, expectedPayments) in [(LiquidityHorizon.days30, 1), (.days60, 2), (.days90, 3)] {
            let result = LiquidityCalculator.result(
                netLoggedPosition: net, pendingItems: pending, horizon: horizon,
                rate: nil, now: now
            )

            // Independently sum the in-window payments straight from the snapshots —
            // this is the "each payment counted exactly once" reference.
            let endDate = now.addingTimeInterval(TimeInterval(horizon.rawValue) * 86_400)
            let inWindow = pending.filter { $0.dueDate <= endDate }
            XCTAssertEqual(inWindow.count, expectedPayments, "\(horizon.rawValue)d window payment count")
            let referenceOut = inWindow.reduce(Decimal(0)) { $0 + $1.amount }

            XCTAssertEqual(result.expectedOut, referenceOut,
                           "expectedOut counts each in-window payment exactly once")
            XCTAssertEqual(result.expectedOut, Decimal(expectedPayments) * 1_000,
                           "\(expectedPayments) payment(s) × 1000, not doubled")
            XCTAssertEqual(result.loanAdjustment, 0, "the loan seam stays zero — no lump balance is injected")
            XCTAssertEqual(result.freeLiquidity, net - referenceOut,
                           "freeLiquidity = net − expectedOut (loanAdjustment contributes nothing)")
        }
    }

    /// The counter-factual that proves WHY the seam stays zero: if a caller ALSO
    /// injected the loan's outstanding balance via `loanAdjustment`, `freeLiquidity`
    /// would swing by that whole balance — double-counting the debt already present
    /// as payment items. Production must never do this.
    func testInjectingOutstandingBalanceWouldDoubleCount() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2025, month: 12, day: 20, hour: 9))!

        let loan = Loan(name: "Credit", lender: "BCR", kind: .bank, principal: 12_000,
                        currency: .ron, annualRatePercent: nil, startDate: start,
                        termMonths: 12, projectID: UUID())
        _ = LoanStore.createLoan(loan, calendar: cal, in: ctx)
        let pending = try ctx.fetch(FetchDescriptor<ScheduledItem>())
            .filter { $0.status == .pending }.map(\.snapshot)

        let outstanding = LoanStore.outstandingPrincipal(for: loan, in: ctx)
        XCTAssertEqual(outstanding, 12_000)

        let production = LiquidityCalculator.result(
            netLoggedPosition: 50_000, pendingItems: pending, horizon: .days90, rate: nil, now: now)
        let doubleCounted = LiquidityCalculator.result(
            netLoggedPosition: 50_000, pendingItems: pending, horizon: .days90, rate: nil,
            loanAdjustment: -outstanding, now: now)

        XCTAssertNotEqual(production.freeLiquidity, doubleCounted.freeLiquidity,
                          "injecting the balance changes the answer — that is the double-count we avoid")
        XCTAssertEqual(doubleCounted.freeLiquidity, production.freeLiquidity - outstanding,
                       "the injected balance is exactly the extra (double-counted) subtraction")
    }
}
