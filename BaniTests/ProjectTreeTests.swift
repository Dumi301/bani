import XCTest
@testable import Bani

/// v0.4 P1 — the project tree engine (`ProjectTree` / `RecurringIncome`), pure
/// value math, no SwiftData. Fixture: a lot with two houses, a rented flat, a
/// prospect, and an orphan whose parent is gone.
final class ProjectTreeTests: XCTestCase {

    // MARK: - Fixture

    private let lotID = UUID(), house1ID = UUID(), house2ID = UUID()
    private let flatID = UUID(), prospectID = UUID(), orphanID = UUID()
    private let ghostParentID = UUID()

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func snap(_ id: UUID, _ name: String, status: ProjectStatus = .active, sort: Int = 0,
                      parent: UUID? = nil, sale: Decimal? = nil, saleDate: Date? = nil) -> ProjectSnapshot {
        ProjectSnapshot(id: id, name: name, status: status, colorIndex: 0, sortOrder: sort, archived: false,
                        createdAt: day(2026, 1, 1), parentProjectID: parent, expectedSalePrice: sale,
                        expectedSaleDate: saleDate, aliases: [])
    }

    private func line(_ amount: Decimal, _ direction: TransactionDirection, _ project: UUID?,
                      bucket: CostBucket = .other, currency: Currency = .ron, date: Date? = nil) -> ProjectTxLine {
        ProjectTxLine(amount: amount, currency: currency, direction: direction, projectID: project,
                      date: date ?? day(2026, 3, 10), bucket: bucket)
    }

    private func item(_ amount: Decimal, _ direction: ScheduledDirection, _ project: UUID?,
                      status: ScheduledStatus = .pending, due: Date, recurrence: RecurrenceRule = .none,
                      seriesID: UUID? = nil, loanID: UUID? = nil, linked: UUID? = nil,
                      title: String = "item", id: UUID = UUID()) -> ScheduledItemSnapshot {
        ScheduledItemSnapshot(id: id, direction: direction, amount: amount, currency: .ron, title: title,
                              descriptionText: "", counterparty: nil, dueDate: due, projectID: project,
                              status: status, linkedTransactionID: linked, createdAt: day(2026, 1, 1),
                              recurrence: recurrence, seriesID: seriesID, loanID: loanID)
    }

    private var projects: [ProjectSnapshot] {
        [
            snap(lotID, "Lot Crângași", sort: 1, sale: 300_000, saleDate: day(2026, 12, 1)),
            snap(house2ID, "Casa 2", sort: 2, parent: lotID),
            snap(house1ID, "Casa 1", sort: 1, parent: lotID),
            snap(flatID, "Garsonieră Militari", sort: 2),
            snap(prospectID, "Teren Chiajna", status: .prospect, sort: 3, sale: 150_000),
            snap(orphanID, "Casa fără lot", sort: 9, parent: ghostParentID),
        ]
    }

    private var lines: [ProjectTxLine] {
        [
            line(100_000, .expense, lotID, bucket: .acquisition, date: day(2026, 1, 15)),
            line(20_000, .expense, house1ID, bucket: .materials, date: day(2026, 2, 1)),
            line(5_000, .expense, house2ID, bucket: .labor, date: day(2026, 3, 1)),
            line(1_000, .expense, lotID, bucket: .labor, date: day(2026, 3, 20)),
            line(700, .expense, lotID, bucket: .other),
            line(9_999, .neutral, lotID),                       // transfer — never counted
            line(250, .expense, nil, bucket: .labor),           // unassigned — never counted
            line(2_000, .income, flatID, date: day(2026, 3, 5)), // rent received
            line(100, .expense, flatID, bucket: .other, currency: .eur), // EUR, needs a rate
        ]
    }

    private var items: [ScheduledItemSnapshot] {
        [
            item(4_000, .outgoing, house2ID, due: day(2026, 4, 1)),                  // due to a worker
            item(9_000, .outgoing, lotID, due: day(2026, 4, 5), loanID: UUID()),      // loan — excluded
            item(500, .outgoing, house1ID, status: .done, due: day(2026, 2, 5)),      // done — not pending
            item(2_000, .incoming, flatID, due: day(2026, 4, 1), recurrence: .monthly, title: "Chirie Militari"),
        ]
    }

    // MARK: - Structure

    func testRootsIncludeOrphansAndSortByOrderThenName() {
        let roots = ProjectTree.roots(projects)
        XCTAssertEqual(roots.map(\.id), [lotID, flatID, prospectID, orphanID],
                       "houses are not roots; the orphan surfaces instead of disappearing")
        XCTAssertEqual(ProjectTree.children(of: lotID, in: projects).map(\.name), ["Casa 1", "Casa 2"])
        XCTAssertEqual(ProjectTree.children(of: flatID, in: projects), [])
    }

    func testDescendantIDsAndRootID() {
        XCTAssertEqual(ProjectTree.descendantIDs(of: lotID, in: projects), [lotID, house1ID, house2ID])
        XCTAssertEqual(ProjectTree.descendantIDs(of: house1ID, in: projects), [house1ID])
        XCTAssertEqual(ProjectTree.rootID(of: house2ID, in: projects), lotID)
        XCTAssertEqual(ProjectTree.rootID(of: orphanID, in: projects), orphanID, "a missing parent makes the orphan its own root")
    }

    func testCycleIsSafe() {
        let a = UUID(), b = UUID()
        let loop = [snap(a, "A", parent: b), snap(b, "B", parent: a)]
        XCTAssertEqual(ProjectTree.descendantIDs(of: a, in: loop), [a, b])
        XCTAssertEqual(ProjectTree.rootID(of: a, in: loop), b, "walks up once and stops")
        XCTAssertEqual(ProjectTree.roots(loop).count, 0, "both have an existing parent — degenerate but terminates")
    }

    // MARK: - Rollups

    func testLotRollsUpItsHousesAndOwnLines() {
        let r = ProjectTree.rollup(lotID, projects: projects, lines: lines, items: items, rate: nil)
        XCTAssertEqual(r.acquisition, 100_000)
        XCTAssertEqual(r.materials, 20_000)
        XCTAssertEqual(r.labor, 6_000, "house 2 labor + lot-level labor")
        XCTAssertEqual(r.otherCosts, 700)
        XCTAssertEqual(r.costs, 26_700)
        XCTAssertEqual(r.invested, 126_700)
        XCTAssertEqual(r.earnings, 0)
        XCTAssertEqual(r.realizedProfit, -126_700)
        XCTAssertEqual(r.pendingOut, 4_000, "pending non-loan outgoing on a child; the loan item is excluded")
        XCTAssertEqual(r.pendingIn, 0)
        XCTAssertEqual(r.expectedSalePrice, 300_000)
        XCTAssertEqual(r.expectedSaleDate, day(2026, 12, 1))
        XCTAssertEqual(r.expectedProfit, 300_000 - 126_700 - 4_000)
        XCTAssertEqual(r.laborPercent, AmortizationSchedule.rounded2(Decimal(6_000) / 26_700 * 100))
        XCTAssertEqual(r.materialsPercent, AmortizationSchedule.rounded2(Decimal(20_000) / 26_700 * 100))
        XCTAssertEqual(r.childCount, 2)
        XCTAssertEqual(r.bucket, .building)
        XCTAssertEqual(r.firstDate, day(2026, 1, 15))
        XCTAssertEqual(r.lastDate, day(2026, 3, 20))
    }

    func testHouseRollupIsScopedAndInheritsNoPrice() {
        let r = ProjectTree.rollup(house2ID, projects: projects, lines: lines, items: items, rate: nil)
        XCTAssertEqual(r.labor, 5_000)
        XCTAssertEqual(r.acquisition, 0)
        XCTAssertEqual(r.pendingOut, 4_000)
        XCTAssertNil(r.expectedSalePrice, "a house without its own price does not borrow the lot's")
        XCTAssertNil(r.expectedProfit)
        XCTAssertEqual(r.bucket, .building)
        XCTAssertEqual(r.childCount, 0)
    }

    func testParentWithoutPriceSumsPricedChildren() {
        let a = UUID(), b = UUID(), lot = UUID()
        let tree = [snap(lot, "Lot"), snap(a, "A", parent: lot, sale: 100, saleDate: day(2026, 6, 1)),
                    snap(b, "B", parent: lot, sale: 150, saleDate: day(2026, 9, 1))]
        let r = ProjectTree.rollup(lot, projects: tree, lines: [], items: [], rate: nil)
        XCTAssertEqual(r.expectedSalePrice, 250)
        XCTAssertEqual(r.expectedSaleDate, day(2026, 9, 1), "the later child sale closes the lot")
    }

    func testRentedFlatIsRentingAndRentCountsAsEarnings() {
        let noRate = ProjectTree.rollup(flatID, projects: projects, lines: lines, items: items, rate: nil)
        XCTAssertEqual(noRate.earnings, 2_000)
        XCTAssertEqual(noRate.otherCosts, 0, "EUR line excluded without a rate")
        XCTAssertEqual(noRate.monthlyRecurringIncome, 2_000)
        XCTAssertEqual(noRate.pendingIn, 2_000)
        XCTAssertEqual(noRate.bucket, .renting)

        let withRate = ProjectTree.rollup(flatID, projects: projects, lines: lines, items: items, rate: 5)
        XCTAssertEqual(withRate.otherCosts, 500, "EUR converts at the rate")
        XCTAssertEqual(withRate.realizedProfit, 1_500)
    }

    func testProspectAndFinishedBuckets() {
        XCTAssertEqual(ProjectTree.rollup(prospectID, projects: projects, lines: lines, items: items, rate: nil).bucket, .planned)
        let done = [snap(lotID, "Lot", status: .finished)]
        XCTAssertEqual(ProjectTree.rollup(lotID, projects: done, lines: [], items: [], rate: nil).bucket, .finished)
    }

    func testRootRollupsFollowRootOrder() {
        let all = ProjectTree.rootRollups(projects: projects, lines: lines, items: items, rate: nil)
        XCTAssertEqual(all.map(\.projectID), [lotID, flatID, prospectID, orphanID])
        XCTAssertEqual(all.map(\.bucket), [.building, .renting, .planned, .building])
    }

    func testCostBucketFromSeededCategory() {
        XCTAssertEqual(CostBucket(seeded: .achizitie), .acquisition)
        XCTAssertEqual(CostBucket(seeded: .manopera), .labor)
        XCTAssertEqual(CostBucket(seeded: .platiPersoane), .labor)
        XCTAssertEqual(CostBucket(seeded: .materialeConstructii), .materials)
        XCTAssertEqual(CostBucket(seeded: .amenajareMobilier), .materials)
        XCTAssertEqual(CostBucket(seeded: .notariatTaxe), .other)
        XCTAssertEqual(CostBucket(seeded: nil), .other)
    }

    // MARK: - Recurring income

    func testMonthlyEquivalent() {
        XCTAssertEqual(RecurringIncome.monthlyEquivalent(1_200, .monthly), 1_200)
        XCTAssertEqual(RecurringIncome.monthlyEquivalent(3_000, .quarterly), 1_000)
        XCTAssertEqual(RecurringIncome.monthlyEquivalent(1_200, .yearly), 100)
        XCTAssertEqual(RecurringIncome.monthlyEquivalent(120, .weekly), 520)
        XCTAssertEqual(RecurringIncome.monthlyEquivalent(999, .none), 0)
    }

    func testSourcesGroupSeriesAndSplitExpectedVsReceived() {
        let salarySeries = UUID()
        let rentSeries = UUID()
        let march = day(2026, 3, 15)
        let rows: [ScheduledItemSnapshot] = [
            // Salary: March occurrence done (linked), April pending — one source.
            item(10_000, .incoming, nil, status: .done, due: day(2026, 3, 10), recurrence: .monthly,
                 seriesID: salarySeries, linked: UUID(), title: "Salariu"),
            item(10_000, .incoming, nil, due: day(2026, 4, 10), recurrence: .monthly,
                 seriesID: salarySeries, title: "Salariu"),
            // Rent: March pending (not yet arrived).
            item(2_000, .incoming, flatID, due: day(2026, 3, 1), recurrence: .monthly,
                 seriesID: rentSeries, title: "Chirie Militari"),
            // A one-shot incoming is not a recurring source.
            item(50_000, .incoming, lotID, due: day(2026, 3, 20), title: "Avans vânzare"),
            // Loan-generated incoming is excluded.
            item(100, .incoming, nil, due: day(2026, 3, 2), recurrence: .monthly, loanID: UUID(), title: "loan"),
        ]
        let sources = RecurringIncome.sources(items: rows, month: march, calendar: calendar, rate: nil)
        XCTAssertEqual(sources.map(\.title), ["Salariu", "Chirie Militari"], "salary first, then rents")

        let salary = sources[0]
        XCTAssertTrue(salary.isSalary)
        XCTAssertEqual(salary.id, salarySeries)
        XCTAssertEqual(salary.amount, 10_000)
        XCTAssertEqual(salary.expectedThisMonth, 10_000)
        XCTAssertEqual(salary.receivedThisMonth, 10_000)
        XCTAssertEqual(salary.nextDueDate, day(2026, 4, 10))

        let rent = sources[1]
        XCTAssertFalse(rent.isSalary)
        XCTAssertEqual(rent.projectID, flatID)
        XCTAssertEqual(rent.expectedThisMonth, 2_000)
        XCTAssertEqual(rent.receivedThisMonth, 0)
        XCTAssertEqual(rent.nextDueDate, day(2026, 3, 1))

        // Monthly total counts one pending occurrence per series.
        XCTAssertEqual(RecurringIncome.monthlyTotal(items: rows, rate: nil), 12_000)
    }
}
