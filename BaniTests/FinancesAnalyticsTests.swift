import XCTest
@testable import Bani

/// D4 — analytics aggregation units: per-category totals, per-day/month
/// bucketing, previous-period alignment (incl. short-month edges), Decimal
/// correctness, and the no-rate fallback. A fixed UTC calendar keeps the date
/// math deterministic (no `.now`, no device timezone).
final class FinancesAnalyticsTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Midnight UTC on the given day.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d))!
    }

    // MARK: - Category totals

    func testByCategoryTotalsAndCountSorted() {
        let items = [
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: day(2026, 7, 1)),
            SpendItem(amount: 20, currency: .ron, category: .fuel, date: day(2026, 7, 2)),
            SpendItem(amount: 5, currency: .ron, category: .dining, date: day(2026, 7, 2)),
        ]
        let cats = FinancesAnalytics.byCategory(items, rate: nil)
        XCTAssertEqual(cats.first?.category, .fuel, "highest total first")
        XCTAssertEqual(cats.first?.total, 30)
        XCTAssertEqual(cats.first?.count, 2)
        XCTAssertEqual(cats.last?.total, 5)
    }

    // MARK: - Decimal correctness + conversion

    func testCombinedTotalWithRate() {
        let items = [
            SpendItem(amount: 100, currency: .ron, category: .fuel, date: day(2026, 7, 1)),
            SpendItem(amount: 10, currency: .eur, category: .dining, date: day(2026, 7, 2)),
        ]
        // 100 RON + 10 EUR × 5.0 = 150 RON
        XCTAssertEqual(FinancesAnalytics.combinedTotal(items, rate: 5), 150)
    }

    func testNoRateFallbackExcludesEURFromCombined() {
        let items = [
            SpendItem(amount: 100, currency: .ron, category: .fuel, date: day(2026, 7, 1)),
            SpendItem(amount: 10, currency: .eur, category: .dining, date: day(2026, 7, 2)),
        ]
        XCTAssertEqual(FinancesAnalytics.combinedTotal(items, rate: nil), 100)
        let byCurrency = FinancesAnalytics.totalsByCurrency(items)
        XCTAssertEqual(byCurrency[.ron], 100)
        XCTAssertEqual(byCurrency[.eur], 10)
    }

    // MARK: - Bucketing

    func testDailyBucketsFillEmptyDays() {
        let interval = DateInterval(start: day(2026, 7, 1), end: day(2026, 7, 4)) // 3 days
        let items = [
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: day(2026, 7, 1)),
            SpendItem(amount: 5, currency: .ron, category: .fuel, date: day(2026, 7, 1)),
            SpendItem(amount: 20, currency: .ron, category: .dining, date: day(2026, 7, 3)),
        ]
        let buckets = FinancesAnalytics.buckets(items, interval: interval, unit: .day, calendar: utc, rate: nil)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].total, 15) // Jul 1
        XCTAssertEqual(buckets[1].total, 0)  // Jul 2 (filled)
        XCTAssertEqual(buckets[2].total, 20) // Jul 3
    }

    func testMonthlyBucketsFillEmptyMonths() {
        let interval = DateInterval(start: day(2026, 5, 1), end: day(2026, 8, 1)) // May, Jun, Jul
        let items = [
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: day(2026, 5, 15)),
            SpendItem(amount: 20, currency: .ron, category: .fuel, date: day(2026, 7, 10)),
        ]
        let buckets = FinancesAnalytics.buckets(items, interval: interval, unit: .month, calendar: utc, rate: nil)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].total, 10) // May
        XCTAssertEqual(buckets[1].total, 0)  // Jun (filled)
        XCTAssertEqual(buckets[2].total, 20) // Jul
    }

    func testAverageBucket() {
        let buckets = [
            FinancesAnalytics.TimeBucket(start: day(2026, 7, 1), total: 10),
            FinancesAnalytics.TimeBucket(start: day(2026, 7, 2), total: 20),
        ]
        XCTAssertEqual(FinancesAnalytics.average(buckets), 15)
    }

    // MARK: - Timeframe / previous-period alignment

    func testMonthWindowAndPreviousShortMonthEdge() {
        // Reference mid-March → current = March, previous = February (28 days, 2026).
        let ref = day(2026, 3, 15)
        let current = TimeframeRange.current(.month, reference: ref, calendar: utc)
        XCTAssertEqual(current.start, day(2026, 3, 1))
        XCTAssertEqual(current.end, day(2026, 4, 1))

        let previous = TimeframeRange.previous(.month, current: current, calendar: utc)
        XCTAssertEqual(previous.start, day(2026, 2, 1))
        XCTAssertEqual(previous.end, day(2026, 3, 1))

        let days = utc.dateComponents([.day], from: previous.start, to: previous.end).day
        XCTAssertEqual(days, 28, "February 2026 has 28 days — the previous window must respect month length")
    }

    func testSixMonthsWindow() {
        let ref = day(2026, 7, 15)
        let current = TimeframeRange.current(.sixMonths, reference: ref, calendar: utc)
        XCTAssertEqual(current.start, day(2026, 2, 1)) // Feb…Jul inclusive
        XCTAssertEqual(current.end, day(2026, 8, 1))
    }

    func testWeekPreviousWindow() {
        let ref = day(2026, 7, 15)
        let current = TimeframeRange.current(.week, reference: ref, calendar: utc)
        let previous = TimeframeRange.previous(.week, current: current, calendar: utc)
        XCTAssertEqual(previous.end, current.start)
        let days = utc.dateComponents([.day], from: previous.start, to: previous.end).day
        XCTAssertEqual(days, 7)
    }

    // MARK: - Cumulative trend alignment

    func testCumulativeRunningSumAndPreviousShift() {
        let items = [
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: day(2026, 6, 2)),
            SpendItem(amount: 5, currency: .ron, category: .fuel, date: day(2026, 6, 10)),
        ]
        let shift: TimeInterval = 30 * 86_400
        let points = FinancesAnalytics.cumulative(items, rate: nil, isPrevious: true, displayShift: shift)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].cumulative, 10)
        XCTAssertEqual(points[1].cumulative, 15) // running sum
        XCTAssertEqual(points[0].alignedDate, day(2026, 6, 2).addingTimeInterval(shift))
        XCTAssertTrue(points[0].isPrevious)
    }
}
