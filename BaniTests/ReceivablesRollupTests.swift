import XCTest
@testable import Bani

/// v1.3 "People registry" — "who owes ME" (VISION §2 Position). Pure logic, no
/// SwiftData: `ScheduledItemSnapshot` is a plain value type, so these
/// construct it directly.
final class ReceivablesRollupTests: XCTestCase {

    private func item(
        counterparty: String?,
        direction: ScheduledDirection,
        status: ScheduledStatus,
        amount: Decimal,
        currency: Currency = .ron,
        dueDate: Date,
        title: String = "Plată"
    ) -> ScheduledItemSnapshot {
        ScheduledItemSnapshot(
            id: UUID(), direction: direction, amount: amount, currency: currency, title: title,
            descriptionText: "", counterparty: counterparty, dueDate: dueDate, projectID: nil,
            status: status, linkedTransactionID: nil, createdAt: .now
        )
    }

    // MARK: - grouping + totals

    func testGroupsByCounterpartyAndTotals() {
        let now = Date()
        let items = [
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 100, dueDate: now.addingTimeInterval(86_400)),
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 50, dueDate: now.addingTimeInterval(2 * 86_400)),
            item(counterparty: "Bob", direction: .incoming, status: .pending, amount: 200, dueDate: now.addingTimeInterval(86_400)),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        XCTAssertEqual(summary.people.count, 2)
        let ana = try! XCTUnwrap(summary.people.first { $0.counterparty == "Ana" })
        XCTAssertEqual(ana.total, 150)
        XCTAssertEqual(ana.count, 2)
        XCTAssertEqual(summary.grandTotal, 350)
    }

    func testItemsSortedSoonestDueFirst() {
        let now = Date()
        let items = [
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 10, dueDate: now.addingTimeInterval(10 * 86_400), title: "later"),
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 10, dueDate: now.addingTimeInterval(86_400), title: "sooner"),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        let ana = try! XCTUnwrap(summary.people.first { $0.counterparty == "Ana" })
        XCTAssertEqual(ana.items.map(\.title), ["sooner", "later"])
    }

    // MARK: - excludes done / outgoing

    func testExcludesDoneAndOutgoing() {
        let now = Date()
        let items = [
            item(counterparty: "Ana", direction: .incoming, status: .done, amount: 100, dueDate: now),
            item(counterparty: "Ana", direction: .outgoing, status: .pending, amount: 999, dueDate: now),
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 40, dueDate: now),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        XCTAssertEqual(summary.grandTotal, 40, "done + outgoing items must never contribute to receivables")
    }

    func testExcludesBlankCounterparty() {
        let items = [
            item(counterparty: nil, direction: .incoming, status: .pending, amount: 100, dueDate: Date()),
            item(counterparty: "   ", direction: .incoming, status: .pending, amount: 100, dueDate: Date()),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        XCTAssertTrue(summary.people.isEmpty)
        XCTAssertEqual(summary.grandTotal, 0)
    }

    // MARK: - overdue

    func testOverdueFlag() {
        let past = Date().addingTimeInterval(-100_000)
        let future = Date().addingTimeInterval(100_000)
        let items = [
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 10, dueDate: past),
            item(counterparty: "Bob", direction: .incoming, status: .pending, amount: 10, dueDate: future),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        let ana = try! XCTUnwrap(summary.people.first { $0.counterparty == "Ana" })
        let bob = try! XCTUnwrap(summary.people.first { $0.counterparty == "Bob" })
        XCTAssertTrue(ana.hasOverdue())
        XCTAssertFalse(bob.hasOverdue())
    }

    // MARK: - recurring items count once (pending occurrence only)

    /// Recurring items (P2) mint exactly ONE pending occurrence per series at a
    /// time (`ScheduledItemStore`'s no-duplicate guard) — so a completed
    /// earlier occurrence (now `.done`) sitting alongside the current
    /// `.pending` one must be counted ONCE, not twice.
    func testRecurringSeriesCountsOnlyThePendingOccurrence() {
        let now = Date()
        let items = [
            item(counterparty: "Ana", direction: .incoming, status: .done, amount: 100,
                 dueDate: now.addingTimeInterval(-30 * 86_400), title: "Chirie (anterioară)"),
            item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 100,
                 dueDate: now, title: "Chirie"),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        let ana = try! XCTUnwrap(summary.people.first { $0.counterparty == "Ana" })
        XCTAssertEqual(ana.count, 1)
        XCTAssertEqual(ana.total, 100)
    }

    // MARK: - currency conversion (mirrors PeopleAnalytics.ronValue)

    func testEURExcludedWithoutRateIncludedWithRate() {
        let items = [item(counterparty: "Ana", direction: .incoming, status: .pending, amount: 100, currency: .eur, dueDate: Date())]
        XCTAssertEqual(ReceivablesRollup.build(items, rate: nil).grandTotal, 0, "EUR without a rate is excluded, not zero-valued")
        XCTAssertEqual(ReceivablesRollup.build(items, rate: nil).people.isEmpty, true)
        XCTAssertEqual(ReceivablesRollup.build(items, rate: 5.0).grandTotal, 500)
    }

    // MARK: - sort order (largest total first)

    func testPeopleSortedByTotalDescending() {
        let now = Date()
        let items = [
            item(counterparty: "Small", direction: .incoming, status: .pending, amount: 10, dueDate: now),
            item(counterparty: "Big", direction: .incoming, status: .pending, amount: 1000, dueDate: now),
        ]
        let summary = ReceivablesRollup.build(items, rate: nil)
        XCTAssertEqual(summary.people.map(\.counterparty), ["Big", "Small"])
    }
}
