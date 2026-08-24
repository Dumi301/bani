import XCTest
import SwiftData
@testable import Bani

/// P11 gate — `SmartSearchService` filter execution over a seeded in-memory
/// `ModelContainer` (mirrors `PersonStoreTests`' SwiftData-backed split): every
/// `SearchFilter` field as an in-memory predicate, intersection with free-text
/// terms via the existing `TransactionSearch`, ranking (date desc; exact-amount
/// boosted), and the Crângași-style query end-to-end through a mock compiler.
final class SmartSearchServiceTests: XCTestCase {

    // MARK: - Seeded container

    @MainActor
    private func seededContainer() throws -> (ModelContainer, [Transaction]) {
        let container = try ModelContainer(for: Transaction.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext

        let crangasiID = UUID()
        let villaID = UUID()

        let rows = [
            Transaction(amount: 500, currency: .ron, context: .work, category: .other,
                        descriptionText: "materiale electrician", merchant: nil,
                        date: date(2026, 4, 10), source: .manual, direction: .expense,
                        counterparty: "Electrician", projectID: crangasiID),
            Transaction(amount: 1200, currency: .ron, context: .work, category: .other,
                        descriptionText: "plata electrician", merchant: nil,
                        date: date(2026, 5, 2), source: .manual, direction: .expense,
                        counterparty: "Electrician", projectID: crangasiID),
            Transaction(amount: 300, currency: .eur, context: .work, category: .other,
                        descriptionText: "vopsea", merchant: "Dedeman",
                        date: date(2026, 4, 20), source: .manual, direction: .expense,
                        counterparty: nil, projectID: crangasiID),
            Transaction(amount: 800, currency: .ron, context: .work, category: .other,
                        descriptionText: "instalatie sanitara", merchant: nil,
                        date: date(2026, 7, 1), source: .manual, direction: .expense,
                        counterparty: "Instalator", projectID: villaID),
            Transaction(amount: 2000, currency: .ron, context: .personal, category: .other,
                        descriptionText: "salariu", merchant: nil,
                        date: date(2026, 4, 25), source: .manual, direction: .income,
                        counterparty: nil, projectID: nil),
            Transaction(amount: 50, currency: .ron, context: .personal, category: .fuel,
                        descriptionText: "benzină", merchant: "OMV",
                        date: date(2026, 8, 1), source: .manual, direction: .expense,
                        counterparty: nil, projectID: nil),
        ]
        rows.forEach { ctx.insert($0) }
        try ctx.save()
        return (container, rows)
    }

    private let calendar = Calendar(identifier: .gregorian)
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    // MARK: - Structured filter execution

    @MainActor
    func testDateRangeFilterExecutes() throws {
        let (_, rows) = try seededContainer()
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.dateRange = DateInterval(start: date(2026, 4, 1), end: date(2026, 6, 1))

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(Set(results.map(\.descriptionText)),
                        ["materiale electrician", "plata electrician", "vopsea", "salariu"])
    }

    @MainActor
    func testAmountRangeFilterExecutes() throws {
        let (_, rows) = try seededContainer()
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.amountMin = 500
        filter.amountMax = 1000

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(Set(results.map(\.descriptionText)), ["materiale electrician", "instalatie sanitara"])
    }

    @MainActor
    func testDirectionAndCurrencyFilterExecute() throws {
        let (_, rows) = try seededContainer()
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.direction = .income

        XCTAssertEqual(SmartSearchService.execute(filter, items: items).map(\.descriptionText), ["salariu"])

        var eurFilter = SearchFilter.empty
        eurFilter.currency = .eur
        XCTAssertEqual(SmartSearchService.execute(eurFilter, items: items).map(\.descriptionText), ["vopsea"])
    }

    @MainActor
    func testProjectFilterExecutes() throws {
        let (_, rows) = try seededContainer()
        let crangasiID = rows[0].projectID!
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.projectIDs = [crangasiID]

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(results.count, 3, "the three Crângași rows, and no others")
        XCTAssertTrue(results.allSatisfy { $0.projectID == crangasiID })
    }

    @MainActor
    func testPersonNamesFilterExecutes() throws {
        let (_, rows) = try seededContainer()
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.personNames = ["Electrician"]

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.counterparty == "Electrician" })
    }

    // MARK: - Intersection with free text

    @MainActor
    func testFreeTextIntersectsWithStructuredFilter() throws {
        let (_, rows) = try seededContainer()
        let crangasiID = rows[0].projectID!
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.projectIDs = [crangasiID]
        filter.freeTextTerms = ["vopsea"]

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(results.map(\.descriptionText), ["vopsea"], "structured + free text intersect, not union")
    }

    @MainActor
    func testFreeTextAloneMatchesLikeExistingKeywordSearch() throws {
        let (_, rows) = try seededContainer()
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.freeTextTerms = ["benzina"] // un-accented — diacritic folding still applies

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(results.map(\.descriptionText), ["benzină"])
    }

    // MARK: - Ranking (date desc; exact-amount boosted)

    @MainActor
    func testRanksDateDescendingByDefault() throws {
        let (_, rows) = try seededContainer()
        let crangasiID = rows[0].projectID!
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.projectIDs = [crangasiID]

        let results = SmartSearchService.execute(filter, items: items)
        let dates = results.map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >), "results are date-descending")
    }

    @MainActor
    func testExactAmountHitIsBoostedAboveNewerNonMatches() throws {
        let (_, rows) = try seededContainer()
        let crangasiID = rows[0].projectID!
        let items = rows.map(SmartSearchService.Item.init)
        var filter = SearchFilter.empty
        filter.projectIDs = [crangasiID]
        filter.exactAmount = 500 // the OLDEST of the three Crângași rows

        let results = SmartSearchService.execute(filter, items: items)
        XCTAssertEqual(results.first?.descriptionText, "materiale electrician",
                        "the exact-amount hit is boosted to the top despite being the oldest match")
    }

    // MARK: - Crângași-style query end-to-end through a mock compiler

    struct MockQueryCompiler: QueryCompiling {
        var proposal: SearchQueryProposal?
        var isAvailable: Bool { true }
        func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal? { proposal }
    }

    @MainActor
    func testCrangasiStyleQueryEndToEnd() async throws {
        // "what did I pay the electrician at the Crângași site last spring"
        let (_, rows) = try seededContainer()
        let crangasi = rows[0].projectID!
        let items = rows.map(SmartSearchService.Item.init)
        let projects = [ProjectSnapshot(id: crangasi, name: "Crângași", status: .active, colorIndex: 0, sortOrder: 0, archived: false, createdAt: Date())]

        let mock = MockQueryCompiler(proposal: SearchQueryProposal(
            relativeDate: .lastSpring, projectName: "Crângași", personName: "Electrician"
        ))
        let now = date(2026, 8, 24) // spring (Mar–May) already ended this year
        let outcome = await SmartSearchService.search(
            query: "what did I pay the electrician at the Crângași site last spring",
            now: now, calendar: calendar, items: items, projects: projects, people: [],
            historicalCounterparties: ["Electrician"], compiler: mock
        )

        XCTAssertNotNil(outcome.filter, "a structured filter compiled — not the raw fallback")
        XCTAssertEqual(outcome.results.map(\.descriptionText), ["plata electrician", "materiale electrician"],
                        "both electrician payments at Crângași within Mar–May 2026, newest first")
    }

    // MARK: - Fallback: unavailable compiler ⇒ raw keyword search, order-preserving

    @MainActor
    func testUnavailableCompilerFallsBackToRawKeywordSearch() async throws {
        let (_, rows) = try seededContainer()
        let items = rows.map(SmartSearchService.Item.init)

        let outcome = await SmartSearchService.search(
            query: "electrician", now: date(2026, 8, 24), calendar: calendar,
            items: items, projects: [], people: [], compiler: UnavailableQueryCompiler()
        )

        XCTAssertNil(outcome.filter, "the fallback marker — no structured filter compiled")
        XCTAssertEqual(outcome.results.map(\.descriptionText), ["materiale electrician", "plata electrician"],
                        "order-preserving — the seeded rows' original order, not re-sorted")
        let expected = SmartSearchService.keywordFallback("electrician", items: items)
        XCTAssertEqual(outcome.results, expected)
    }
}
