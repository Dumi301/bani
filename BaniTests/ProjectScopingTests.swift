import XCTest
@testable import Bani

/// v1.2a — the project dashboard aggregates are scoped by `projectID` with NO
/// leakage: one project's numbers never include another project's rows, and
/// Personal/unassigned (`projectID == nil`) is never counted under any project.
final class ProjectScopingTests: XCTestCase {

    private let rate: Decimal = 5   // 1 EUR = 5 RON, fixed
    private let projectA = UUID()
    private let projectB = UUID()

    private func line(_ amount: Decimal, _ dir: TransactionDirection, project: UUID?, _ currency: Currency = .ron) -> ProjectTxLine {
        ProjectTxLine(amount: amount, currency: currency, direction: dir, projectID: project)
    }

    private var lines: [ProjectTxLine] {
        [
            line(100, .expense, project: projectA),
            line(400, .income, project: projectA),
            line(50, .expense, project: projectB),
            line(999, .expense, project: nil),      // Personal / unassigned — must never leak
            line(20, .neutral, project: projectA),  // neutral — excluded from totals
        ]
    }

    func testScopeReturnsOnlyThatProject() {
        XCTAssertEqual(ProjectAnalytics.scoped(lines, to: projectA).count, 3)
        XCTAssertEqual(ProjectAnalytics.scoped(lines, to: projectB).count, 1)
    }

    func testProjectTotalsDoNotLeakAcrossProjectsOrPersonal() {
        let a = ProjectAnalytics.totals(ProjectAnalytics.scoped(lines, to: projectA), rate: rate)
        XCTAssertEqual(a.spent, 100, "only A's expense — not B's 50, not Personal's 999")
        XCTAssertEqual(a.received, 400)
        XCTAssertEqual(a.net, 300)

        let b = ProjectAnalytics.totals(ProjectAnalytics.scoped(lines, to: projectB), rate: rate)
        XCTAssertEqual(b.spent, 50)
        XCTAssertEqual(b.received, 0)
    }

    func testNeutralExcludedFromProjectTotals() {
        let a = ProjectAnalytics.totals(ProjectAnalytics.scoped(lines, to: projectA), rate: rate)
        XCTAssertEqual(a.spent, 100)   // neutral 20 not counted
        XCTAssertEqual(a.received, 400)
    }

    func testNetLoggedPositionCountsEverything() {
        // income 400 − expenses (100 + 50 + 999) = −749; neutral excluded.
        XCTAssertEqual(ProjectAnalytics.netLoggedPosition(lines, rate: rate), -749)
    }

    func testMixedCurrencyConvertsAtRate() {
        let mixed = [line(10, .expense, project: projectA, .eur)]  // 10 EUR → 50 RON
        XCTAssertEqual(ProjectAnalytics.totals(mixed, rate: rate).spent, 50)
    }

    func testCurrencySplitIsNativeBeforeConversion() {
        let mixed = [
            line(100, .expense, project: projectA, .ron),
            line(10, .expense, project: projectA, .eur),
        ]
        let split = ProjectAnalytics.totalsByCurrency(mixed)
        XCTAssertEqual(split[.ron], 100)
        XCTAssertEqual(split[.eur], 10, "EUR shown natively, never converted, in the split")
    }

    func testPendingRollupIncludesOverdueExcludesDoneFindsNearest() {
        let now = Date()
        func item(_ dir: ScheduledDirection, _ amount: Decimal, dueInDays: Double, status: ScheduledStatus = .pending) -> ScheduledItemSnapshot {
            ScheduledItemSnapshot(id: UUID(), direction: dir, amount: amount, currency: .ron, title: "t",
                                  descriptionText: "", counterparty: nil,
                                  dueDate: now.addingTimeInterval(dueInDays * 86_400), projectID: projectA,
                                  status: status, linkedTransactionID: nil, createdAt: now)
        }
        let overdue = item(.outgoing, 6000, dueInDays: -3)
        let items = [
            overdue,
            item(.incoming, 12000, dueInDays: 10),
            item(.outgoing, 1, dueInDays: 5, status: .done),  // done excluded
        ]
        let rollup = ProjectAnalytics.pendingRollup(items, rate: rate)
        XCTAssertEqual(rollup.outgoing, 6000)   // overdue included, done excluded
        XCTAssertEqual(rollup.incoming, 12000)
        XCTAssertEqual(rollup.net, 6000)
        XCTAssertEqual(rollup.nearestDueDate, overdue.dueDate)
    }
}
