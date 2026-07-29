import XCTest
@testable import Bani

/// A4 — the shared analytics dataset derivation: a tapped bar maps to the exact
/// bucket date range (incl. month-length edges), and the timeframe / category /
/// search filters compose over the SAME item set the charts aggregate. A fixed
/// UTC calendar keeps the date math deterministic.
final class AnalyticsDerivationTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d))!
    }

    // MARK: - Bucket → date range (bar tap filter)

    func testBucketRangeDaily() {
        let range = FinancesAnalytics.bucketRange(start: day(2026, 7, 15), unit: .day, calendar: utc)
        XCTAssertEqual(range.start, day(2026, 7, 15))
        XCTAssertEqual(range.end, day(2026, 7, 16))
    }

    func testBucketRangeMonthLengthEdges() {
        // February 2026 is 28 days — the bar covers exactly [Feb 1, Mar 1).
        let feb = FinancesAnalytics.bucketRange(start: day(2026, 2, 1), unit: .month, calendar: utc)
        XCTAssertEqual(feb.end, day(2026, 3, 1))
        XCTAssertEqual(utc.dateComponents([.day], from: feb.start, to: feb.end).day, 28)

        // December rolls into the next year, 31 days.
        let dec = FinancesAnalytics.bucketRange(start: day(2026, 12, 1), unit: .month, calendar: utc)
        XCTAssertEqual(dec.end, day(2027, 1, 1))
        XCTAssertEqual(utc.dateComponents([.day], from: dec.start, to: dec.end).day, 31)
    }

    func testTappedBarFiltersToExactlyThatBucket() {
        let items = [
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: day(2026, 7, 1)),
            SpendItem(amount: 20, currency: .ron, category: .dining, date: day(2026, 7, 20)),
            SpendItem(amount: 30, currency: .ron, category: .fuel, date: day(2026, 8, 1)),
        ]
        let july = FinancesAnalytics.bucketRange(start: day(2026, 7, 1), unit: .month, calendar: utc)
        let inJuly = items.filter { $0.date >= july.start && $0.date < july.end }
        XCTAssertEqual(inJuly.count, 2, "the Aug 1 item is outside the July bar")
        XCTAssertEqual(inJuly.reduce(Decimal(0)) { $0 + $1.amount }, 30)
    }

    // MARK: - Shared-dataset composition (timeframe + category + search)

    func testTimeframeAndCategoryComposeOverTheSameSet() {
        let interval = DateInterval(start: day(2026, 7, 1), end: day(2026, 8, 1))
        let items = [
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: day(2026, 7, 5)),
            SpendItem(amount: 20, currency: .ron, category: .dining, date: day(2026, 7, 6)),
            SpendItem(amount: 99, currency: .ron, category: .fuel, date: day(2026, 6, 30)), // out of window
        ]
        let windowed = FinancesAnalytics.items(items, in: interval)
        XCTAssertEqual(windowed.count, 2, "the June item is outside the July window")

        // The list drills the SAME windowed set by category…
        let fuelOnly = windowed.filter { $0.categoryRef == .preset(.fuel) }
        XCTAssertEqual(fuelOnly.count, 1)
        XCTAssertEqual(fuelOnly.first?.amount, 10)
        // …and the charts aggregate that same windowed set, so they agree.
        let totals = FinancesAnalytics.byCategory(windowed, rate: nil)
        XCTAssertEqual(totals.first { $0.categoryRef == .preset(.fuel) }?.total, 10)
        XCTAssertEqual(totals.first { $0.categoryRef == .preset(.dining) }?.total, 20)
    }

    func testSearchAndCategoryComposeWithCustomCategory() {
        let sport = CustomCategorySnapshot(id: UUID(), name: "Sport", symbolName: "figure.run", colorIndex: 0)
        let q = TransactionSearch.fold("sport")
        let customs = TransactionSearch.customCategoriesMatching(foldedQuery: q, customCategories: [sport])
        XCTAssertTrue(customs.contains(sport.id), "a custom category is found by its (folded) name")

        // A transaction in that custom category matches the query by category…
        let inSport = TransactionSearch.Fields(descriptionText: "padel", customCategoryID: sport.id)
        XCTAssertTrue(TransactionSearch.matches(inSport, foldedQuery: q, matchingCategories: [], matchingCustoms: customs))
        // …a preset fuel transaction without the word does not.
        let fuel = TransactionSearch.Fields(descriptionText: "benzina", category: .fuel)
        XCTAssertFalse(TransactionSearch.matches(fuel, foldedQuery: q, matchingCategories: [], matchingCustoms: customs))
    }
}
