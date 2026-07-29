import XCTest
@testable import Bani

/// C4 — editing a transaction's date across a month boundary must re-bucket the
/// analytics/charts. Drives `FinancesAnalytics.buckets` directly with a fixed
/// Gregorian/UTC calendar so it is deterministic (no `.now`, no local timezone).
final class DateBucketingTests: XCTestCase {

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        fixedCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testEditingDateAcrossMonthBoundaryRebucketsAggregation() {
        let calendar = fixedCalendar()
        // Analytics window covering July + August 2026.
        let windowStart = date(2026, 7, 1, 0)
        let windowEnd = date(2026, 9, 1, 0)
        let interval = DateInterval(start: windowStart, end: windowEnd)

        let julyBucketStart = date(2026, 7, 1, 0)
        let augustBucketStart = date(2026, 8, 1, 0)

        // Before the edit: the expense sits on July 31 → the July bucket.
        let before = [SpendItem(amount: Decimal(100), currency: .ron, category: .fuel, date: date(2026, 7, 31))]
        let bucketsBefore = FinancesAnalytics.buckets(before, interval: interval, unit: .month, calendar: calendar, rate: nil)
        XCTAssertEqual(bucketsBefore.count, 2, "two month buckets: July and August")
        XCTAssertEqual(bucketsBefore.first { $0.start == julyBucketStart }?.total, Decimal(100))
        XCTAssertEqual(bucketsBefore.first { $0.start == augustBucketStart }?.total, Decimal(0))

        // Edit the date to August 1 → the SAME amount re-buckets into August.
        let after = [SpendItem(amount: Decimal(100), currency: .ron, category: .fuel, date: date(2026, 8, 1))]
        let bucketsAfter = FinancesAnalytics.buckets(after, interval: interval, unit: .month, calendar: calendar, rate: nil)
        XCTAssertEqual(bucketsAfter.first { $0.start == julyBucketStart }?.total, Decimal(0),
                       "July no longer holds the expense after the edit")
        XCTAssertEqual(bucketsAfter.first { $0.start == augustBucketStart }?.total, Decimal(100),
                       "August now holds the re-bucketed expense")
    }
}
