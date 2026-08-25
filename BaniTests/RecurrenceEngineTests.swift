import XCTest
@testable import Bani

/// Pure recurrence math (v2 "Recurring ScheduledItems"). No `ModelContext`, no
/// UI - every rule + edge case is exercised directly against `RecurrenceEngine`.
/// A Europe/Bucharest `Calendar` is injected everywhere (never `.current`) so
/// results are deterministic regardless of the CI runner's system timezone.
final class RecurrenceEngineTests: XCTestCase {

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9, minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - nextDueDate: each rule

    func testNextDueDateNoneReturnsNil() {
        let cal = bucharestCalendar()
        let d = makeDate(2026, 3, 15, calendar: cal)
        XCTAssertNil(RecurrenceEngine.nextDueDate(after: d, rule: .none, calendar: cal))
    }

    func testNextDueDateWeeklyAddsSevenDays() {
        let cal = bucharestCalendar()
        let d = makeDate(2026, 3, 5, calendar: cal)
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .weekly, calendar: cal)
        XCTAssertEqual(next, makeDate(2026, 3, 12, calendar: cal))
    }

    func testNextDueDateMonthlyAdvancesOneMonth() {
        let cal = bucharestCalendar()
        let d = makeDate(2026, 3, 15, calendar: cal)
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .monthly, calendar: cal)
        XCTAssertEqual(next, makeDate(2026, 4, 15, calendar: cal))
    }

    func testNextDueDateQuarterlyAdvancesThreeMonths() {
        let cal = bucharestCalendar()
        let d = makeDate(2026, 1, 10, calendar: cal)
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .quarterly, calendar: cal)
        XCTAssertEqual(next, makeDate(2026, 4, 10, calendar: cal))
    }

    func testNextDueDateYearlyAdvancesOneYear() {
        let cal = bucharestCalendar()
        let d = makeDate(2026, 6, 1, calendar: cal)
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .yearly, calendar: cal)
        XCTAssertEqual(next, makeDate(2027, 6, 1, calendar: cal))
    }

    // MARK: - Month-end clamping

    func testNextDueDateMonthlyClampsJan31ToFeb28InNonLeapYear() {
        let cal = bucharestCalendar()
        let d = makeDate(2027, 1, 31, calendar: cal) // 2027 is NOT a leap year
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .monthly, calendar: cal)
        XCTAssertEqual(next, makeDate(2027, 2, 28, calendar: cal), "Jan 31 + monthly clamps to Feb 28 in a non-leap year")
    }

    func testNextDueDateMonthlyClampsJan31ToFeb29InLeapYear() {
        let cal = bucharestCalendar()
        let d = makeDate(2028, 1, 31, calendar: cal) // 2028 IS a leap year
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .monthly, calendar: cal)
        XCTAssertEqual(next, makeDate(2028, 2, 29, calendar: cal), "Jan 31 + monthly clamps to Feb 29 in a leap year")
    }

    func testNextDueDateMonthlyClampsAug31ToSep30() {
        let cal = bucharestCalendar()
        let d = makeDate(2026, 8, 31, calendar: cal)
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .monthly, calendar: cal)
        XCTAssertEqual(next, makeDate(2026, 9, 30, calendar: cal), "Aug 31 + monthly clamps to Sep 30 (Sep has no 31st)")
    }

    func testNextDueDateYearlyClampsFeb29ToFeb28OnNonLeapTargetYear() {
        let cal = bucharestCalendar()
        let d = makeDate(2028, 2, 29, calendar: cal) // 2028 leap
        let next = RecurrenceEngine.nextDueDate(after: d, rule: .yearly, calendar: cal)
        XCTAssertEqual(next, makeDate(2029, 2, 28, calendar: cal), "Feb 29 + yearly clamps to Feb 28 when the target year isn't leap")
    }

    // MARK: - DST transitions (Europe/Bucharest)

    /// Spring-forward: clocks jump 03:00 -> 04:00 local on the last Sunday of
    /// March (2026-03-29). A raw 86400-second addition would land one hour off
    /// local wall-clock time; Calendar `.day` component addition preserves the
    /// 09:00 wall-clock time across the transition.
    func testNextDueDateWeeklyPreservesWallClockAcrossSpringForwardDST() {
        let cal = bucharestCalendar()
        let before = makeDate(2026, 3, 22, hour: 9, calendar: cal) // week before the DST Sunday
        let next = RecurrenceEngine.nextDueDate(after: before, rule: .weekly, calendar: cal)
        let expected = makeDate(2026, 3, 29, hour: 9, calendar: cal) // the DST spring-forward Sunday itself
        XCTAssertEqual(next, expected, "weekly recurrence must land on the correct calendar day across spring-forward")
        XCTAssertEqual(cal.component(.hour, from: next!), 9, "wall-clock hour must stay 09:00 across the DST jump")
    }

    /// Fall-back: clocks step 04:00 -> 03:00 local on the last Sunday of October
    /// (2026-10-27) - that Sunday has 25 real hours. Calendar `.day` addition
    /// still preserves the 09:00 wall-clock time.
    func testNextDueDateWeeklyPreservesWallClockAcrossFallBackDST() {
        let cal = bucharestCalendar()
        let before = makeDate(2026, 10, 20, hour: 9, calendar: cal) // week before the fall-back Sunday
        let next = RecurrenceEngine.nextDueDate(after: before, rule: .weekly, calendar: cal)
        let expected = makeDate(2026, 10, 27, hour: 9, calendar: cal) // the DST fall-back Sunday itself
        XCTAssertEqual(next, expected, "weekly recurrence must land on the correct calendar day across fall-back")
        XCTAssertEqual(cal.component(.hour, from: next!), 9, "wall-clock hour must stay 09:00 across the DST jump")
    }

    /// Monthly addition spans the same spring-forward boundary internally
    /// (Mar 15 -> Apr 15 crosses Mar 29) and must also preserve wall-clock time.
    func testNextDueDateMonthlySpanningSpringForwardDSTPreservesWallClock() {
        let cal = bucharestCalendar()
        let before = makeDate(2026, 3, 15, hour: 9, calendar: cal)
        let next = RecurrenceEngine.nextDueDate(after: before, rule: .monthly, calendar: cal)
        XCTAssertEqual(next, makeDate(2026, 4, 15, hour: 9, calendar: cal))
        XCTAssertEqual(cal.component(.hour, from: next!), 9)
    }

    // MARK: - makeNextOccurrence

    func testMakeNextOccurrenceCopiesFieldsAdvancesDateKeepsSeriesID() {
        let cal = bucharestCalendar()
        let existingSeries = UUID()
        let projectID = UUID()
        let due = makeDate(2026, 5, 10, calendar: cal)
        let item = ScheduledItem(
            direction: .outgoing, amount: 6000, currency: .ron, title: "Chirie",
            descriptionText: "Chirie lunara", counterparty: "Ion", dueDate: due,
            projectID: projectID, status: .pending, recurrence: .monthly, seriesID: existingSeries
        )

        let next = RecurrenceEngine.makeNextOccurrence(from: item, calendar: cal)

        let unwrapped = next!
        XCTAssertEqual(unwrapped.title, item.title)
        XCTAssertEqual(unwrapped.descriptionText, item.descriptionText)
        XCTAssertEqual(unwrapped.amount, item.amount)
        XCTAssertEqual(unwrapped.currency, item.currency)
        XCTAssertEqual(unwrapped.direction, item.direction)
        XCTAssertEqual(unwrapped.counterparty, item.counterparty)
        XCTAssertEqual(unwrapped.projectID, item.projectID)
        XCTAssertEqual(unwrapped.status, .pending)
        XCTAssertEqual(unwrapped.dueDate, makeDate(2026, 6, 10, calendar: cal), "dueDate advances by one month")
        XCTAssertEqual(unwrapped.seriesID, existingSeries, "an already-set seriesID is kept, not re-minted")
    }

    func testMakeNextOccurrenceMintsSeriesIDWhenNilWithoutMutatingOrigin() {
        let cal = bucharestCalendar()
        let item = ScheduledItem(
            direction: .incoming, amount: 100, currency: .eur, title: "t",
            dueDate: makeDate(2026, 4, 1, calendar: cal), recurrence: .weekly, seriesID: nil
        )

        let next = RecurrenceEngine.makeNextOccurrence(from: item, calendar: cal)

        XCTAssertNotNil(next!.seriesID, "a nil origin seriesID mints a fresh one on the next occurrence")
        XCTAssertNil(item.seriesID, "makeNextOccurrence is PURE - it must not mutate the origin item")
    }

    func testMakeNextOccurrenceReturnsNilForNoneRecurrence() {
        let cal = bucharestCalendar()
        let item = ScheduledItem(
            direction: .outgoing, amount: 50, currency: .ron, title: "one-shot",
            dueDate: makeDate(2026, 4, 1, calendar: cal), recurrence: .none
        )
        XCTAssertNil(RecurrenceEngine.makeNextOccurrence(from: item, calendar: cal))
    }
}
