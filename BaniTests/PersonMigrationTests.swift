import XCTest
import SwiftData
@testable import Bani

/// v1.3 "People registry" — proves the ONE frozen-seam addition is migration-
/// safe on a REAL on-disk store (write → close → reopen), the class of change
/// that can destroy user data. Unlike `Project` / `Loan`, `Person` adds ZERO
/// fields to any existing entity: `Transaction.counterparty` /
/// `ScheduledItem.counterparty` stay plain strings, matched by normalized name
/// only (never an FK — see `PersonStore`). So there is no legacy COLUMN shape
/// to replicate; registering the table is proven by writing REAL `Transaction`
/// / `ScheduledItem` rows (with populated `counterparty` strings) under a
/// pre-Person container, reopening under the current schema (adds ONLY the
/// new `Person` table), and confirming every row — and every counterparty
/// string VERBATIM — survives untouched, with the new table present and empty
/// (registry rows are never auto-created from history).

private func freshStoreURL(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bani-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("store.sqlite")
}

/// The pre-v1.3 model set (mirrors `BaniModelContainer.schema` MINUS `Person`).
private func legacyContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        Project.self, ScheduledItem.self, Loan.self,
        configurations: ModelConfiguration(url: url)
    )
}

/// The current app's full model set (mirrors `BaniModelContainer.schema`), now
/// including the v1.3 `Person` entity — anchored AFTER `Project.self`, matching
/// the real registration in `BaniModelContainer`.
private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        Project.self, Person.self, ScheduledItem.self, Loan.self,
        configurations: ModelConfiguration(url: url)
    )
}

@MainActor
final class PersonMigrationTests: XCTestCase {

    func testLegacyStoreReopensCleanWithEmptyPersonTableAndCounterpartyStringsIntact() throws {
        let url = try freshStoreURL("person-legacy")
        let txID = UUID(), itemID = UUID()

        do {
            let container = try legacyContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Transaction(id: txID, amount: 500, currency: .ron, context: .work,
                                    descriptionText: "avans chirie", source: .manual,
                                    direction: .income, counterparty: "Ștefan Popescu"))
            ctx.insert(ScheduledItem(id: itemID, direction: .incoming, amount: 1200, currency: .ron,
                                      title: "Rest plată", counterparty: "Ion Ionescu",
                                      dueDate: Date(timeIntervalSince1970: 1_770_000_000)))
            try ctx.save()
        }

        // Reopen under the CURRENT schema (adds ONLY the new Person table).
        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txs.count, 1, "the legacy transaction must migrate into the new schema")
        XCTAssertEqual(txs.first?.counterparty, "Ștefan Popescu", "counterparty string is NEVER rewritten by the registry")
        XCTAssertEqual(txs.first?.id, txID)

        let items = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.counterparty, "Ion Ionescu")
        XCTAssertEqual(items.first?.id, itemID)

        // The new table exists and is EMPTY on a migrated store — Person rows
        // are never auto-created from historical counterparty strings.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Person>()), 0)
    }

    /// Round-trip: a `Person` persists, closes, reopens, intact — including the
    /// stored `normalizedName` and the optional `kind`/`notes` fields.
    func testPersonRoundTrip() throws {
        let url = try freshStoreURL("person-roundtrip")
        let personID = UUID()

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Person(id: personID, name: "Ștefan Popescu",
                               normalizedName: PersonStore.normalizedKey("Ștefan Popescu"),
                               kind: .client, notes: "Chiriaș apartament"))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let people = try container.mainContext.fetch(FetchDescriptor<Person>())
        let person = try XCTUnwrap(people.first { $0.id == personID })
        XCTAssertEqual(person.name, "Ștefan Popescu")
        XCTAssertEqual(person.normalizedName, "stefan popescu")
        XCTAssertEqual(person.kind, .client)
        XCTAssertEqual(person.notes, "Chiriaș apartament")
    }

    /// Optional fields (`kind`, `notes`) decode to `nil` when absent — the same
    /// additive-optional discipline as every other new entity in this app.
    func testPersonOptionalFieldsDefaultNil() throws {
        let url = try freshStoreURL("person-optionals")
        let personID = UUID()

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Person(id: personID, name: "Ion", normalizedName: PersonStore.normalizedKey("Ion")))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let person = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<Person>()).first { $0.id == personID })
        XCTAssertNil(person.kind)
        XCTAssertNil(person.notes)
    }

    func testPersonKindRawValuesStable() {
        XCTAssertEqual(PersonKind.client.rawValue, "client")
        XCTAssertEqual(PersonKind.vendor.rawValue, "vendor")
        XCTAssertEqual(PersonKind.lender.rawValue, "lender")
        XCTAssertEqual(PersonKind.other.rawValue, "other")
    }
}
