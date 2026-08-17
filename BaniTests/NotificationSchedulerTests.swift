import XCTest
@testable import Bani

/// v1.2a — the reminder scheduling *logic* is a pure unit (no real delivery in CI):
/// deterministic identifiers, the 09:00-local trigger, the enable/cancel gates, and
/// the localized copy. `ReminderService` is the thin system wrapper this proves out.
final class NotificationSchedulerTests: XCTestCase {

    private func item(
        _ direction: ScheduledDirection = .outgoing,
        amount: Decimal = 6000,
        currency: Currency = .ron,
        counterparty: String? = "Ion",
        title: String = "Plată",
        dueInDays: Int,
        status: ScheduledStatus = .pending,
        id: UUID = UUID()
    ) -> ScheduledItemSnapshot {
        let due = Calendar.current.date(byAdding: .day, value: dueInDays, to: Date()) ?? Date()
        return ScheduledItemSnapshot(
            id: id, direction: direction, amount: amount, currency: currency,
            title: title, descriptionText: "", counterparty: counterparty,
            dueDate: due, projectID: nil, status: status, linkedTransactionID: nil, createdAt: Date()
        )
    }

    func testIdentifierIsDeterministicAndPrefixed() {
        let id = UUID()
        XCTAssertEqual(NotificationScheduler.identifier(for: id), "bani.reminder.\(id.uuidString)")
        XCTAssertEqual(NotificationScheduler.identifier(for: id), NotificationScheduler.identifier(for: id))
        XCTAssertTrue(NotificationScheduler.isBaniReminder(NotificationScheduler.identifier(for: id)))
        XCTAssertFalse(NotificationScheduler.isBaniReminder("some.other.notification"))
    }

    func testFireDateIsNineAMLocalOnDueDate() throws {
        let snapshot = item(dueInDays: 10)
        let fire = try XCTUnwrap(NotificationScheduler.fireDate(for: snapshot))
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: fire), 9)
        XCTAssertEqual(cal.component(.minute, from: fire), 0)
        // Same calendar day as the due date.
        XCTAssertTrue(cal.isDate(fire, inSameDayAs: snapshot.dueDate))
    }

    func testTriggerComponentsCarryNineAM() throws {
        let comps = try XCTUnwrap(NotificationScheduler.triggerComponents(for: item(dueInDays: 5)))
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertNotNil(comps.day)
    }

    func testDoneItemsAreNeverScheduled() {
        let done = item(dueInDays: 10, status: .done)
        XCTAssertNil(NotificationScheduler.fireDate(for: done))
        XCTAssertFalse(NotificationScheduler.shouldSchedule(done, now: Date()))
    }

    func testFuturePendingSchedulesButOverdueDoesNot() {
        let now = Date()
        XCTAssertTrue(NotificationScheduler.shouldSchedule(item(dueInDays: 10), now: now),
                      "a pending, future item should be scheduled")
        XCTAssertFalse(NotificationScheduler.shouldSchedule(item(dueInDays: -5), now: now),
                       "an overdue item is surfaced as an in-app flag, never a (past) notification")
    }

    func testBodyIncludesCounterpartyAmountCurrencyAndProject() {
        let snapshot = item(counterparty: "Ion", dueInDays: 3)
        let body = NotificationScheduler.body(for: snapshot, projectName: "Proiect Manhattan")
        XCTAssertTrue(body.contains("Ion"))
        XCTAssertTrue(body.contains(Currency.ron.displayCode))
        XCTAssertTrue(body.contains("Proiect Manhattan"))
    }

    func testBodyFallsBackToTitleWhenNoCounterparty() {
        let snapshot = item(counterparty: nil, title: "Chirie", dueInDays: 3)
        let body = NotificationScheduler.body(for: snapshot, projectName: nil)
        XCTAssertTrue(body.contains("Chirie"))
        XCTAssertFalse(body.contains("("), "no project → no parenthetical")
    }

    func testDirectionTitleDiffersByDirection() {
        XCTAssertNotEqual(
            NotificationScheduler.title(for: item(.incoming, dueInDays: 1)),
            NotificationScheduler.title(for: item(.outgoing, dueInDays: 1))
        )
    }
}
