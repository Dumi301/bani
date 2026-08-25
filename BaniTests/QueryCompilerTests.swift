import XCTest
import Foundation
@testable import Bani

/// P11 gate — the query-compiling seam (`QueryCompiler`). Pure logic, no
/// SwiftData, the Foundation Models pass behind an injected mock `QueryCompiling`
/// (CI has no FM runtime). Proves the hard laws:
///   • RO + EN queries compile to the expected `SearchFilter`, including
///     relative-date resolution against a FIXED `now` (never `Date()` inline).
///   • A proposed project/person/custom-category that does not exist is DROPPED
///     (anti-hallucination — P10's rule, reused).
///   • A person is verifiable via EITHER the P6 registry OR a real historical
///     counterparty string.
///   • Empty compile (nothing usable) ⇒ nil — the fallback marker.
///   • Non-blocking: a hung/slow compiler times out ⇒ nil (fallback).
final class QueryCompilerTests: XCTestCase {

    // MARK: - Mock FM seam (the CI injection point)

    struct MockQueryCompiler: QueryCompiling {
        var available: Bool = true
        var proposal: SearchQueryProposal?
        var delay: Duration?

        var isAvailable: Bool { available }
        func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal? {
            if let delay { try? await Task.sleep(for: delay) }
            return proposal
        }
    }

    private let unavailable = UnavailableQueryCompiler()
    private let calendar = Calendar(identifier: .gregorian)

    /// Fixed reference "now" for every relative-date assertion — 2026-08-24.
    private var fixedNow: Date { date(2026, 8, 24) }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private func project(_ name: String) -> ProjectSnapshot {
        ProjectSnapshot(id: UUID(), name: name, status: .active, colorIndex: 0, sortOrder: 0, archived: false, createdAt: Date())
    }
    private func person(_ name: String) -> PersonSnapshot {
        PersonSnapshot(id: UUID(), name: name, normalizedName: Categorizer.normalize(name), kind: nil, notes: nil, createdAt: Date())
    }

    // MARK: - RO + EN corpus → expected SearchFilter

    func testEnglishQueryCompilesProjectPersonAndRelativeDate() async throws {
        // "what did I pay the electrician at the Crângași site last spring" (VISION §3).
        let crangasi = project("Crângași")
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(
            relativeDate: .lastSpring, projectName: "Crângași", personName: "Electrician", remainderText: "electrician"
        ))
        let compiled = await QueryCompiler.compile(
            query: "what did I pay the electrician at the Crângași site last spring",
            now: fixedNow, calendar: calendar, projects: [crangasi], people: [],
            historicalCounterparties: ["Electrician"], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.projectIDs, [crangasi.id])
        XCTAssertEqual(filter.personNames, ["Electrician"])
        XCTAssertEqual(filter.freeTextTerms, ["electrician"])
        // Explicit brief assertion: "Mar–May of the correct year" — now is Aug
        // 2026, this year's spring already ended → the 2026 instance.
        XCTAssertEqual(filter.dateRange, DateInterval(start: date(2026, 3, 1), end: date(2026, 6, 1)))
    }

    func testRomanianLastMonthPhrase() async throws {
        // "chirie luna trecută" — rent, last month.
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(relativeDate: .lastMonth, remainderText: "chirie"))
        let compiled = await QueryCompiler.compile(
            query: "chirie luna trecută", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.dateRange, DateInterval(start: date(2026, 7, 1), end: date(2026, 8, 1)))
        XCTAssertEqual(filter.freeTextTerms, ["chirie"])
    }

    func testRomanianNamedMonthPhrase() async throws {
        // "cheltuieli în aprilie" — spending in April.
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(relativeDate: .april))
        let compiled = await QueryCompiler.compile(
            query: "cheltuieli în aprilie", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.dateRange, DateInterval(start: date(2026, 4, 1), end: date(2026, 5, 1)))
    }

    func testAmountRangeDirectionAndCurrencyCompile() async throws {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(
            amountMin: 200, amountMax: 500, currency: .ron, direction: .expense
        ))
        let compiled = await QueryCompiler.compile(
            query: "expenses between 200 and 500 RON", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.amountMin, 200)
        XCTAssertEqual(filter.amountMax, 500)
        XCTAssertEqual(filter.currency, .ron)
        XCTAssertEqual(filter.direction, .expense)
    }

    func testExactAmountCompiles() async throws {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(exactAmount: Decimal(string: "1200")))
        let compiled = await QueryCompiler.compile(
            query: "the 1200 lei payment", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.exactAmount, Decimal(string: "1200"))
    }

    func testPresetCategoryCompiles() async throws {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(presetCategory: .fuel))
        let compiled = await QueryCompiler.compile(
            query: "fuel spending", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.categoryRefs, [.preset(.fuel)])
    }

    func testVerifiedCustomCategoryCompiles() async throws {
        let sport = CustomCategorySnapshot(id: UUID(), name: "Sport", symbolName: "figure.run", colorIndex: 0)
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(customCategoryName: "Sport"))
        let compiled = await QueryCompiler.compile(
            query: "sport spending", now: fixedNow, calendar: calendar, projects: [], people: [],
            customCategories: [sport], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.categoryRefs, [.custom(sport.id)])
    }

    // MARK: - Anti-hallucination (verification disposes — P10's rule, reused)

    func testHallucinatedProjectIsDropped() async {
        let real = project("Villa Aurora")
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(projectName: "Skyline Penthouse Tower"))
        let filter = await QueryCompiler.compile(
            query: "spending at Skyline Penthouse Tower", now: fixedNow, calendar: calendar,
            projects: [real], people: [], compiler: mock
        )
        XCTAssertNil(filter, "a proposed project that does not exist compiles to nil (nothing usable survives verification)")
    }

    func testHallucinatedPersonIsDropped() async {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(personName: "Imaginary Client SRL"))
        let filter = await QueryCompiler.compile(
            query: "payments to Imaginary Client SRL", now: fixedNow, calendar: calendar,
            projects: [], people: [person("Ion Popescu")], historicalCounterparties: [], compiler: mock
        )
        XCTAssertNil(filter, "a proposed person matching neither the registry nor history is dropped")
    }

    func testHallucinatedCustomCategoryIsDropped() async {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(customCategoryName: "Imaginary Category"))
        let filter = await QueryCompiler.compile(
            query: "imaginary category spending", now: fixedNow, calendar: calendar,
            projects: [], people: [], customCategories: [], compiler: mock
        )
        XCTAssertNil(filter)
    }

    func testPersonVerifiedAgainstRegistry() async throws {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(personName: "ion popescu"))
        let compiled = await QueryCompiler.compile(
            query: "payments to Ion", now: fixedNow, calendar: calendar,
            projects: [], people: [person("Ion Popescu")], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.personNames, ["Ion Popescu"], "resolves to the registry's canonical casing")
    }

    func testPersonVerifiedAgainstHistoricalCounterpartyWhenUnregistered() async throws {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(personName: "Bolt"))
        let compiled = await QueryCompiler.compile(
            query: "rides with Bolt", now: fixedNow, calendar: calendar,
            projects: [], people: [], historicalCounterparties: ["Bolt"], compiler: mock
        )
        let filter = try XCTUnwrap(compiled)
        XCTAssertEqual(filter.personNames, ["Bolt"], "a real counterparty string is a valid verification pool even when never registered")
    }

    // MARK: - Empty compile → fallback marker

    func testEmptyProposalCompilesToNilFallbackMarker() async {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal.none)
        let filter = await QueryCompiler.compile(
            query: "asdkjhasd", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        XCTAssertNil(filter, "a proposal with nothing usable compiles to nil, the fallback marker")
    }

    func testUnavailableCompilerCompilesToNil() async {
        let filter = await QueryCompiler.compile(
            query: "anything", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: unavailable
        )
        XCTAssertNil(filter, "FM unavailable ⇒ nil, the same fallback marker")
    }

    func testBlankQueryCompilesToNil() async {
        let mock = MockQueryCompiler(proposal: SearchQueryProposal(presetCategory: .fuel))
        let filter = await QueryCompiler.compile(
            query: "   ", now: fixedNow, calendar: calendar, projects: [], people: [], compiler: mock
        )
        XCTAssertNil(filter, "a blank query never reaches the compiler")
    }

    // MARK: - Non-blocking (a hung compiler times out, falls back)

    func testSlowCompilerTimesOutToNil() async {
        let hung = MockQueryCompiler(proposal: SearchQueryProposal(presetCategory: .fuel), delay: .seconds(10))
        let start = Date()
        let filter = await QueryCompiler.compile(
            query: "fuel", now: fixedNow, calendar: calendar, projects: [], people: [],
            compiler: hung, timeout: .milliseconds(20)
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(filter, "a timed-out compile falls back")
        XCTAssertLessThan(elapsed, 2.0, "compile returns promptly — it never waits out a hung model")
    }

    // MARK: - RelativeDateResolver (direct — spring-in-progress edge case)

    func testLastSpringWhileCurrentlyInSpringStepsBackAYear() {
        // Standing INSIDE this year's spring (April), "last spring" is the
        // spring before it — not the one still in progress.
        let nowInApril = date(2026, 4, 15)
        let range = RelativeDateResolver.resolve(.lastSpring, now: nowInApril, calendar: calendar)
        XCTAssertEqual(range, DateInterval(start: date(2025, 3, 1), end: date(2025, 6, 1)))
    }

    func testLastWinterWrapsTheYearBoundary() {
        let nowInJanuary = date(2026, 1, 15)
        let range = RelativeDateResolver.resolve(.lastWinter, now: nowInJanuary, calendar: calendar)
        XCTAssertEqual(range, DateInterval(start: date(2024, 12, 1), end: date(2025, 3, 1)))
    }
}
