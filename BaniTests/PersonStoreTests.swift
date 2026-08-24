import XCTest
import SwiftData
@testable import Bani

/// v1.3 "People registry" — pure logic + a live in-memory `ModelContext` for
/// create/find, mirroring the codebase's split between pure unit tests and
/// SwiftData-backed ones (`PeopleAnalytics` vs `ProjectMigrationTests`).
final class PersonStoreTests: XCTestCase {

    // MARK: - normalize/dedup

    func testNormalizeFoldsDiacritics() {
        XCTAssertEqual(PersonStore.normalizedKey("Ștefan"), PersonStore.normalizedKey("Stefan"))
        XCTAssertEqual(PersonStore.normalizedKey("Ștefan"), "stefan")
    }

    func testNormalizeTrimsAndLowercases() {
        XCTAssertEqual(PersonStore.normalizedKey("  Ion Popescu  "), PersonStore.normalizedKey("ion popescu"))
        XCTAssertEqual(PersonStore.normalizedKey("ION POPESCU"), "ion popescu")
    }

    @MainActor
    func testFindOrCreateDedupsByNormalizedName() throws {
        let container = try inMemoryContainer()
        let ctx = container.mainContext

        let first = try XCTUnwrap(PersonStore.findOrCreate(name: "Ștefan Popescu", in: ctx))
        let second = try XCTUnwrap(PersonStore.findOrCreate(name: "stefan popescu", in: ctx))
        XCTAssertEqual(first.id, second.id, "a diacritic/case variant must resolve to the SAME registered person")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Person>()), 1, "no duplicate row is created")
    }

    @MainActor
    func testFindOrCreateRejectsBlankName() throws {
        let container = try inMemoryContainer()
        let ctx = container.mainContext
        XCTAssertNil(PersonStore.findOrCreate(name: "   ", in: ctx))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Person>()), 0)
    }

    @MainActor
    func testFindReturnsNilWhenUnregistered() throws {
        let container = try inMemoryContainer()
        let ctx = container.mainContext
        XCTAssertNil(PersonStore.find(name: "Nimeni", in: ctx))
    }

    // MARK: - historicalCounterparties

    @MainActor
    func testHistoricalCounterpartiesDedupsAcrossTransactionAndScheduledItem() throws {
        let tx = Transaction(amount: 10, currency: .ron, context: .work, descriptionText: "x",
                              date: Date(timeIntervalSince1970: 100), source: .manual, counterparty: "Ana")
        let item = ScheduledItem(direction: .incoming, amount: 10, currency: .ron, title: "y",
                                  counterparty: "ana", dueDate: Date(timeIntervalSince1970: 200))
        let out = PersonStore.historicalCounterparties(transactions: [tx], scheduledItems: [item])
        XCTAssertEqual(out.count, 1, "the same normalized name from both sources dedups to one entry")
        XCTAssertEqual(out.first, "Ana")
    }

    @MainActor
    func testHistoricalCounterpartiesSkipsBlank() throws {
        let tx = Transaction(amount: 10, currency: .ron, context: .work, descriptionText: "x", source: .manual, counterparty: "   ")
        let out = PersonStore.historicalCounterparties(transactions: [tx], scheduledItems: [])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - suggestions merge (registry-first, no duplicates)

    func testSuggestionsRegistryFirstNoDuplicates() {
        let suggestions = PersonStore.suggestions(
            prefix: "",
            people: ["Ana Maria", "Bogdan"],
            historicalCounterparties: ["ana maria", "Cristina", "Bogdan"]
        )
        XCTAssertEqual(suggestions, ["Ana Maria", "Bogdan", "Cristina"],
                        "registry entries come first; historical variants of a registered name never duplicate it")
    }

    func testSuggestionsFilterByPrefix() {
        let suggestions = PersonStore.suggestions(
            prefix: "st",
            people: ["Ștefan Popescu", "Ana"],
            historicalCounterparties: ["Studio X"]
        )
        XCTAssertEqual(suggestions, ["Ștefan Popescu", "Studio X"])
    }

    func testSuggestionsLimit() {
        let people = (0..<20).map { "Person \($0)" }
        let suggestions = PersonStore.suggestions(prefix: "", people: people, historicalCounterparties: [], limit: 5)
        XCTAssertEqual(suggestions.count, 5)
    }

    func testSuggestionsSkipsBlankEntries() {
        let suggestions = PersonStore.suggestions(prefix: "", people: ["", "  ", "Ana"], historicalCounterparties: [""])
        XCTAssertEqual(suggestions, ["Ana"])
    }

    // MARK: - helpers

    @MainActor
    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: Person.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
