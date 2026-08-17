import XCTest
import SwiftData
@testable import Bani

/// v1.2a "Projects Core" — proves the three frozen-seam additions are migration-
/// safe on a REAL on-disk store (close + reopen), the one class of change that can
/// destroy user data:
///   • `Transaction.projectID` — optional additive attribute (the proven-safe
///     pattern; NO non-optional additions — the direction-crash lesson is law).
///   • new entities `Project` + `ScheduledItem`.
///
/// A store written in the v1.0.36 shape (BEFORE `projectID` / `Project` /
/// `ScheduledItem` existed) reopens under the new schema with every row readable,
/// `projectID == nil`, zero data loss; and a full round-trip of all three persists,
/// closes, reopens, intact.

/// The v1.0.36 shape of the persisted `Transaction`: every column that existed
/// BEFORE this run added `projectID`. Nested in an enum so its SwiftData entity
/// name is still `"Transaction"` (the same on-disk table as `Bani.Transaction`)
/// while the Swift type stays distinct — the standard versioned-schema idiom,
/// mirroring `LegacyStoreV26` in `DirectionNullMigrationTests`.
private enum LegacyStoreV36 {
    @Model final class Transaction {
        var id: UUID
        var amount: Decimal
        var currency: Currency
        var context: TransactionContext
        var category: TransactionCategory?
        var customCategoryID: UUID?
        var descriptionText: String
        var merchant: String?
        var date: Date
        var rawTranscript: String?
        var source: TransactionSource
        // Same optional-backed `direction` column as v1.0.36 ships (originalName
        // keeps the on-disk column name identical).
        @Attribute(originalName: "direction") private var directionStored: TransactionDirection?
        var counterparty: String?
        var attachmentID: UUID?
        var importBatchID: UUID?
        var createdAt: Date

        init(id: UUID = UUID(), amount: Decimal, currency: Currency, context: TransactionContext,
             descriptionText: String, source: TransactionSource,
             direction: TransactionDirection = .expense,
             counterparty: String? = nil, importBatchID: UUID? = nil,
             date: Date = .now, createdAt: Date = .now) {
            self.id = id
            self.amount = amount
            self.currency = currency
            self.context = context
            self.category = nil
            self.customCategoryID = nil
            self.descriptionText = descriptionText
            self.merchant = nil
            self.date = date
            self.rawTranscript = nil
            self.source = source
            self.directionStored = direction
            self.counterparty = counterparty
            self.attachmentID = attachmentID
            self.importBatchID = importBatchID
            self.createdAt = createdAt
        }
    }
}

/// A fresh, empty on-disk store URL in a temp directory.
private func freshStoreURL(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bani-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("store.sqlite")
}

/// The current app's full model set (mirrors `BaniModelContainer.schema`), now
/// including the two v1.2a entities.
private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        Project.self, ScheduledItem.self,
        configurations: ModelConfiguration(url: url)
    )
}

@MainActor
final class ProjectMigrationTests: XCTestCase {

    /// v1.0.36-shaped store (no `projectID`, no `Project`/`ScheduledItem` tables)
    /// reopens under the new schema: every row readable, `projectID` nil, and the
    /// other additive optionals untouched → zero data loss.
    func testV36StoreReopensWithProjectIDNilAndNoDataLoss() throws {
        let url = try freshStoreURL("proj-v36")
        let aID = UUID(), bID = UUID(), cID = UUID()

        // 1. Write rows in the v1.0.36 shape. Scoped so the container closes.
        do {
            let container = try ModelContainer(
                for: LegacyStoreV36.Transaction.self,
                configurations: ModelConfiguration(url: url)
            )
            let ctx = container.mainContext
            ctx.insert(LegacyStoreV36.Transaction(id: aID, amount: 52, currency: .ron, context: .personal,
                                                   descriptionText: "benzină", source: .voice))
            ctx.insert(LegacyStoreV36.Transaction(id: bID, amount: 6000, currency: .ron, context: .work,
                                                   descriptionText: "chirie primită", source: .imported,
                                                   direction: .income, counterparty: "Ion"))
            ctx.insert(LegacyStoreV36.Transaction(id: cID, amount: 120, currency: .eur, context: .work,
                                                   descriptionText: "transport", source: .manual,
                                                   importBatchID: UUID()))
            try ctx.save()
        }

        // 2. Reopen under the CURRENT schema (adds projectID column + two tables).
        let container = try currentContainer(at: url)
        let rows = try container.mainContext.fetch(FetchDescriptor<Transaction>())

        // Non-vacuous: the legacy rows MUST migrate into the current schema.
        XCTAssertEqual(rows.count, 3, "v1.0.36 rows must migrate into the new schema")
        XCTAssertTrue(rows.allSatisfy { $0.projectID == nil }, "every migrated row's projectID must be nil")

        // Every prior field is intact — zero data loss.
        let a = try XCTUnwrap(rows.first { $0.id == aID })
        XCTAssertEqual(a.amount, 52); XCTAssertEqual(a.direction, .expense); XCTAssertEqual(a.source, .voice)
        let b = try XCTUnwrap(rows.first { $0.id == bID })
        XCTAssertEqual(b.direction, .income); XCTAssertEqual(b.counterparty, "Ion"); XCTAssertEqual(b.amount, 6000)
        let c = try XCTUnwrap(rows.first { $0.id == cID })
        XCTAssertEqual(c.currency, .eur); XCTAssertNotNil(c.importBatchID)

        // The two new tables exist and are empty on a migrated store.
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ScheduledItem>()), 0)
    }

    /// Round-trip: a `Project`, a `ScheduledItem`, and a `Transaction` carrying
    /// that project's id persist, close, reopen, and stay intact + linked.
    func testProjectScheduledItemAndProjectIDRoundTrip() throws {
        let url = try freshStoreURL("proj-roundtrip")
        let projectID = UUID(), itemID = UUID(), txID = UUID(), linkedTxID = UUID()
        let due = Date(timeIntervalSince1970: 1_770_000_000)

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Project(id: projectID, name: "Proiect Manhattan", status: .active,
                               colorIndex: 3, sortOrder: 1))
            ctx.insert(ScheduledItem(id: itemID, direction: .outgoing, amount: 6000, currency: .ron,
                                     title: "Plată Ion", counterparty: "Ion", dueDate: due,
                                     projectID: projectID, status: .pending,
                                     linkedTransactionID: linkedTxID))
            ctx.insert(Transaction(id: txID, amount: 6000, currency: .ron, context: .work,
                                   descriptionText: "avans", source: .manual, projectID: projectID))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let project = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Project>()).first)
        XCTAssertEqual(project.id, projectID)
        XCTAssertEqual(project.name, "Proiect Manhattan")
        XCTAssertEqual(project.status, .active)
        XCTAssertEqual(project.colorIndex, 3)
        XCTAssertFalse(project.archived)

        let item = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ScheduledItem>()).first)
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.direction, .outgoing)
        XCTAssertEqual(item.amount, 6000)
        XCTAssertEqual(item.dueDate, due)
        XCTAssertEqual(item.projectID, projectID)
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.linkedTransactionID, linkedTxID)

        let tx = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(tx.id, txID)
        XCTAssertEqual(tx.projectID, projectID, "the transaction must still point at its project after reopen")
    }

    /// Enum raw values are stable — SwiftData persists the rawValue, so these must
    /// never drift (a rename would orphan every stored row).
    func testStatusEnumRawValuesStable() {
        XCTAssertEqual(ProjectStatus.active.rawValue, "active")
        XCTAssertEqual(ProjectStatus.finished.rawValue, "finished")
        XCTAssertEqual(ScheduledDirection.incoming.rawValue, "incoming")
        XCTAssertEqual(ScheduledDirection.outgoing.rawValue, "outgoing")
        XCTAssertEqual(ScheduledStatus.pending.rawValue, "pending")
        XCTAssertEqual(ScheduledStatus.done.rawValue, "done")
    }

    /// The mark-done direction mapping is the documented contract:
    /// incoming → income, outgoing → expense.
    func testScheduledDirectionMapsToTransactionDirection() {
        XCTAssertEqual(ScheduledDirection.incoming.transactionDirection, .income)
        XCTAssertEqual(ScheduledDirection.outgoing.transactionDirection, .expense)
    }
}
