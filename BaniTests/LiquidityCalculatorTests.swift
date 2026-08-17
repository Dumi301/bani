import XCTest
@testable import Bani

/// v1.2a — the liquidity answer is a pure computation with its own tests: horizons,
/// mixed currencies (fixed test rate), overdue inclusion, and empty states. This is
/// the seam v1.2b injects loan balances into, so it is proven independent of any UI.
final class LiquidityCalculatorTests: XCTestCase {

    /// Fixed test rate — never network. 1 EUR = 5 RON keeps the arithmetic obvious.
    private let rate: Decimal = 5

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func item(
        _ direction: ScheduledDirection,
        _ amount: Decimal,
        _ currency: Currency = .ron,
        dueInDays: Double,
        status: ScheduledStatus = .pending
    ) -> ScheduledItemSnapshot {
        ScheduledItemSnapshot(
            id: UUID(), direction: direction, amount: amount, currency: currency,
            title: "t", descriptionText: "", counterparty: nil,
            dueDate: now.addingTimeInterval(dueInDays * 86_400),
            projectID: nil, status: status, linkedTransactionID: nil, createdAt: now
        )
    }

    // MARK: Empty states

    func testEmptyItemsYieldsNetPositionAsFreeLiquidity() {
        let r = LiquidityCalculator.result(
            netLoggedPosition: 1000, pendingItems: [], horizon: .days30, rate: rate, now: now
        )
        XCTAssertEqual(r.expectedIn, 0)
        XCTAssertEqual(r.expectedOut, 0)
        XCTAssertEqual(r.freeLiquidity, 1000)
        XCTAssertFalse(r.hasUnconvertibleCurrency)
    }

    func testEmptyEverythingIsZero() {
        let r = LiquidityCalculator.result(
            netLoggedPosition: 0, pendingItems: [], horizon: .days90, rate: nil, now: now
        )
        XCTAssertEqual(r.freeLiquidity, 0)
        XCTAssertEqual(r.netExpected, 0)
    }

    // MARK: Horizons

    func testHorizonExcludesItemsBeyondWindow() {
        let items = [
            item(.incoming, 100, dueInDays: 10),   // in 30/60/90
            item(.incoming, 200, dueInDays: 45),   // in 60/90 only
            item(.incoming, 400, dueInDays: 80),   // in 90 only
        ]
        let r30 = LiquidityCalculator.result(netLoggedPosition: 0, pendingItems: items, horizon: .days30, rate: rate, now: now)
        let r60 = LiquidityCalculator.result(netLoggedPosition: 0, pendingItems: items, horizon: .days60, rate: rate, now: now)
        let r90 = LiquidityCalculator.result(netLoggedPosition: 0, pendingItems: items, horizon: .days90, rate: rate, now: now)
        XCTAssertEqual(r30.expectedIn, 100)
        XCTAssertEqual(r60.expectedIn, 300)
        XCTAssertEqual(r90.expectedIn, 700)
    }

    func testFreeLiquidityCombinesNetInAndOut() {
        let items = [
            item(.incoming, 500, dueInDays: 5),
            item(.outgoing, 200, dueInDays: 12),
        ]
        let r = LiquidityCalculator.result(netLoggedPosition: 1000, pendingItems: items, horizon: .days30, rate: rate, now: now)
        XCTAssertEqual(r.expectedIn, 500)
        XCTAssertEqual(r.expectedOut, 200)
        XCTAssertEqual(r.netExpected, 300)
        XCTAssertEqual(r.freeLiquidity, 1300) // 1000 + 500 − 200
    }

    // MARK: Overdue inclusion

    func testOverdueItemsAreIncluded() {
        let items = [
            item(.outgoing, 6000, dueInDays: -10), // overdue: due 10 days ago, still owed
            item(.incoming, 1000, dueInDays: -3),  // overdue incoming, still expected
            item(.outgoing, 500, dueInDays: 5),    // upcoming
        ]
        let r = LiquidityCalculator.result(netLoggedPosition: 2000, pendingItems: items, horizon: .days30, rate: rate, now: now)
        XCTAssertEqual(r.expectedOut, 6500) // 6000 overdue + 500 upcoming
        XCTAssertEqual(r.expectedIn, 1000)  // overdue incoming counted
        XCTAssertEqual(r.freeLiquidity, 2000 + 1000 - 6500)
    }

    func testDoneItemsAreExcluded() {
        let items = [
            item(.incoming, 999, dueInDays: 5, status: .done),
            item(.incoming, 100, dueInDays: 5, status: .pending),
        ]
        let r = LiquidityCalculator.result(netLoggedPosition: 0, pendingItems: items, horizon: .days30, rate: rate, now: now)
        XCTAssertEqual(r.expectedIn, 100, "done items must not count toward expected money")
    }

    // MARK: Mixed currencies

    func testMixedCurrenciesConvertAtFixedRate() {
        let items = [
            item(.incoming, 100, .eur, dueInDays: 5), // 100 EUR → 500 RON
            item(.incoming, 250, .ron, dueInDays: 5), // 250 RON
            item(.outgoing, 20, .eur, dueInDays: 5),  // 20 EUR → 100 RON
        ]
        let r = LiquidityCalculator.result(netLoggedPosition: 0, pendingItems: items, horizon: .days30, rate: rate, now: now)
        XCTAssertEqual(r.expectedIn, 750)  // 500 + 250
        XCTAssertEqual(r.expectedOut, 100)
        XCTAssertFalse(r.hasUnconvertibleCurrency)
    }

    func testMissingRateSkipsEURAndFlags() {
        let items = [
            item(.incoming, 100, .eur, dueInDays: 5), // unconvertible without a rate
            item(.incoming, 250, .ron, dueInDays: 5),
        ]
        let r = LiquidityCalculator.result(netLoggedPosition: 0, pendingItems: items, horizon: .days30, rate: nil, now: now)
        XCTAssertEqual(r.expectedIn, 250, "RON still counts; EUR is skipped, never guessed")
        XCTAssertTrue(r.hasUnconvertibleCurrency)
    }

    // MARK: v1.2b seam

    func testLoanAdjustmentSeamDefaultsToZeroAndAddsWhenInjected() {
        let base = LiquidityCalculator.result(netLoggedPosition: 1000, pendingItems: [], horizon: .days30, rate: rate, now: now)
        XCTAssertEqual(base.loanAdjustment, 0)
        XCTAssertEqual(base.freeLiquidity, 1000)
        // Simulate the v1.2b injection to prove the seam wires into freeLiquidity.
        let withLoan = LiquidityCalculator.result(netLoggedPosition: 1000, pendingItems: [], horizon: .days30, rate: rate, loanAdjustment: -300, now: now)
        XCTAssertEqual(withLoan.freeLiquidity, 700)
    }
}
