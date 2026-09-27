import XCTest
@testable import Bani

/// v0.3 gate — avans clamp/default + per-project activity span.
final class PlanningCardTests: XCTestCase {

    func testAvansIsFreeMinusReserveClampedAtZero() {
        XCTAssertEqual(RaportHubBuilder.availableDownPayment(freeLiquidity: 50_000, reserve: 12_000), 38_000)
        XCTAssertEqual(RaportHubBuilder.availableDownPayment(freeLiquidity: 5_000, reserve: 12_000), 0)
    }

    func testDefaultReserveIsHorizonOutgoings() {
        let liquidity = LiquidityResult(netLoggedPosition: 100, expectedIn: 10, expectedOut: 7_500,
                                        loanAdjustment: 0, horizonDays: 30, hasUnconvertibleCurrency: false)
        XCTAssertEqual(RaportHubBuilder.defaultReserve(liquidity), 7_500)
    }

    func testProjectRowCarriesFirstAndLastTransactionDates() {
        let project = ProjectSnapshot(id: UUID(), name: "Crângași", status: .active, colorIndex: 0,
                                      sortOrder: 0, archived: false, createdAt: .now)
        let d0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lines = [
            RaportTxLine(amount: 100, currency: .ron, direction: .expense, projectID: project.id, loanID: nil, date: d0.addingTimeInterval(86_400 * 5)),
            RaportTxLine(amount: 300, currency: .ron, direction: .income, projectID: project.id, loanID: nil, date: d0),
            RaportTxLine(amount: 999, currency: .ron, direction: .expense, projectID: nil, loanID: nil, date: d0.addingTimeInterval(86_400 * 50)),
        ]
        let model = RaportHubBuilder.build(
            lines: lines, loans: [], projects: [project], items: [], rate: nil, horizon: .days30,
            cashflowInterval: DateInterval(start: .distantPast, end: .distantFuture)
        )
        let row = try! XCTUnwrap(model.projects.first)
        XCTAssertEqual(row.firstDate, d0)
        XCTAssertEqual(row.lastDate, d0.addingTimeInterval(86_400 * 5))
        XCTAssertEqual(row.invested, 100)
        XCTAssertEqual(row.net, 200)
    }
}
