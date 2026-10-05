import XCTest
@testable import Bani

/// v0.4 P2 — the home screen's new blocks on the hub model: project-tree
/// rollups (acquisition + costs vs earnings per lot), recurring income (salary
/// + rents) and personal spend. Pure value inputs, no SwiftData — the view
/// feeds `RaportHubBuilder.build` exactly these shapes.
final class HomeModelTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testHomeBlocks() throws {
        let lotID = UUID(), houseID = UUID(), flatID = UUID(), prospectID = UUID()
        let now = day(2026, 3, 15)
        let projects = [
            ProjectSnapshot(id: lotID, name: "Lot", status: .active, colorIndex: 0, sortOrder: 1, archived: false,
                            createdAt: now, expectedSalePrice: 300_000),
            ProjectSnapshot(id: houseID, name: "Casa 1", status: .active, colorIndex: 1, sortOrder: 1, archived: false,
                            createdAt: now, parentProjectID: lotID),
            ProjectSnapshot(id: flatID, name: "Garsonieră", status: .active, colorIndex: 2, sortOrder: 2, archived: false,
                            createdAt: now),
            ProjectSnapshot(id: prospectID, name: "Teren", status: .prospect, colorIndex: 3, sortOrder: 3, archived: false,
                            createdAt: now, expectedSalePrice: 150_000),
        ]
        let lines = [
            RaportTxLine(amount: 100_000, currency: .ron, direction: .expense, projectID: lotID, loanID: nil,
                         date: day(2026, 1, 10), bucket: .acquisition),
            RaportTxLine(amount: 5_000, currency: .ron, direction: .expense, projectID: houseID, loanID: nil,
                         date: day(2026, 3, 1), bucket: .labor),
            RaportTxLine(amount: 2_000, currency: .ron, direction: .income, projectID: flatID, loanID: nil,
                         date: day(2026, 3, 2)),
            RaportTxLine(amount: 800, currency: .ron, direction: .expense, projectID: nil, loanID: nil,
                         date: day(2026, 3, 5), isPersonal: true),
            RaportTxLine(amount: 300, currency: .ron, direction: .expense, projectID: nil, loanID: nil,
                         date: day(2026, 3, 6)), // work, unassigned — not personal
        ]
        let salarySeries = UUID()
        let items = [
            ScheduledItemSnapshot(id: UUID(), direction: .incoming, amount: 10_000, currency: .ron, title: "Salariu",
                                  descriptionText: "", counterparty: nil, dueDate: day(2026, 3, 10), projectID: nil,
                                  status: .done, linkedTransactionID: UUID(), createdAt: now,
                                  recurrence: .monthly, seriesID: salarySeries),
            ScheduledItemSnapshot(id: UUID(), direction: .incoming, amount: 10_000, currency: .ron, title: "Salariu",
                                  descriptionText: "", counterparty: nil, dueDate: day(2026, 4, 10), projectID: nil,
                                  status: .pending, linkedTransactionID: nil, createdAt: now,
                                  recurrence: .monthly, seriesID: salarySeries),
            ScheduledItemSnapshot(id: UUID(), direction: .incoming, amount: 2_000, currency: .ron, title: "Chirie",
                                  descriptionText: "", counterparty: nil, dueDate: day(2026, 4, 1), projectID: flatID,
                                  status: .pending, linkedTransactionID: nil, createdAt: now, recurrence: .monthly),
        ]
        let month = try XCTUnwrap(calendar.dateInterval(of: .month, for: now))

        let model = RaportHubBuilder.build(
            lines: lines, loans: [], projects: projects, items: items, rate: nil,
            horizon: .days30, cashflowInterval: month, now: now, calendar: calendar
        )

        // Position: personal spend over the cash-flow period, work spend excluded.
        XCTAssertEqual(model.position.personalSpend, 800)
        XCTAssertEqual(model.position.cashOut, 100_000 + 5_000 + 800 + 300 - 100_000, "cash-flow window is March only")

        // Rollups: one per root, in root order, grouped by derived bucket.
        XCTAssertEqual(model.rollups.map(\.projectID), [lotID, flatID, prospectID])
        let lot = model.rollups[0]
        XCTAssertEqual(lot.acquisition, 100_000)
        XCTAssertEqual(lot.labor, 5_000, "the house's labor rolls up into the lot")
        XCTAssertEqual(lot.expectedProfit, 300_000 - 105_000)
        XCTAssertEqual(lot.bucket, .building)
        XCTAssertEqual(model.rollups[1].bucket, .renting)
        XCTAssertEqual(model.rollups[1].monthlyRecurringIncome, 2_000)
        XCTAssertEqual(model.rollups[2].bucket, .planned)

        // Legacy project rows still exist for the Excel exporters.
        XCTAssertEqual(model.projects.count, 4)

        // Recurring income: salary first (received this month), then the rent.
        XCTAssertEqual(model.recurringIncome.map(\.title), ["Salariu", "Chirie"])
        XCTAssertEqual(model.recurringIncome[0].receivedThisMonth, 10_000)
        XCTAssertEqual(model.recurringIncome[0].expectedThisMonth, 10_000)
        XCTAssertEqual(model.recurringIncome[1].expectedThisMonth, 0, "April rent is not due in March")
        XCTAssertEqual(model.recurringIncome[1].nextDueDate, day(2026, 4, 1))
    }
}
