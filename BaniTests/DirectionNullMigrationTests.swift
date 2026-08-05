import XCTest
import SwiftData
@testable import Bani

/// Bug A — the Finances-tab update-install crash (`Bani-2026-08-02-233214.ips`):
/// a row written before `direction` existed (≤ v1.0.26) holds NULL in that column,
/// and faulting it dynamic-cast NULL into the (former) non-optional enum → SIGABRT
/// the moment `FinancesView` renders. The fix stores `direction` in an OPTIONAL
/// backing attribute under the same on-disk column name, exposing `.expense`
/// through a computed accessor. These two tests write a REAL on-disk store and
/// reopen it with the current schema — the one class of change that can destroy
/// user data, so it must be proven on disk, not in memory.

/// The v1.0.26 shape of the persisted `Transaction`: the columns that existed
/// BEFORE v1.1 added `direction` / `counterparty` / `attachmentID` /
/// `importBatchID`. Nested in an enum so its SwiftData entity name is still
/// `"Transaction"` (the same on-disk table as `Bani.Transaction`) while the Swift
/// type stays distinct — the standard versioned-schema idiom.
private enum LegacyStoreV26 {
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
        var createdAt: Date

        init(id: UUID = UUID(), amount: Decimal, currency: Currency, context: TransactionContext,
             descriptionText: String, source: TransactionSource, date: Date = .now, createdAt: Date = .now) {
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

/// The current app's full model set (mirrors `ImportTestSupport.inMemoryContainer`).
private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        configurations: ModelConfiguration(url: url)
    )
}

@MainActor
final class DirectionNullMigrationTests: XCTestCase {

    func testLegacyRowsWithNoDirectionColumnReadAsExpense() throws {
        let url = try freshStoreURL("dir-null")

        // 1. Write 3 rows with the v1.0.26 schema — this store has NO `direction`
        //    column at all. Scoped so the container closes before we reopen.
        do {
            let container = try ModelContainer(
                for: LegacyStoreV26.Transaction.self,
                configurations: ModelConfiguration(url: url)
            )
            let ctx = container.mainContext
            ctx.insert(LegacyStoreV26.Transaction(amount: 10, currency: .ron, context: .personal, descriptionText: "legacy expense", source: .manual))
            ctx.insert(LegacyStoreV26.Transaction(amount: 20, currency: .eur, context: .work, descriptionText: "legacy voice", source: .voice))
            ctx.insert(LegacyStoreV26.Transaction(amount: 30, currency: .ron, context: .personal, descriptionText: "legacy third", source: .manual))
            try ctx.save()
        }

        // 2. Reopen the SAME store URL with the CURRENT app schema. Pre-fix this
        //    SIGABRTs when `.direction` faults NULL into the non-optional enum;
        //    post-fix every legacy row reads `.expense`.
        let container = try currentContainer(at: url)
        let ctx = container.mainContext
        let rows = try ctx.fetch(FetchDescriptor<Transaction>())

        // Non-vacuous: the legacy rows MUST have migrated into the current schema
        // (guards against the entity names silently not matching → an empty fetch).
        XCTAssertEqual(rows.count, 3, "legacy rows must migrate into the current schema")
        for row in rows {
            XCTAssertEqual(row.direction, .expense, "legacy NULL direction must read as .expense, not crash")
        }
        // The other v1.1 additive optionals migrate to nil, untouched.
        XCTAssertTrue(rows.allSatisfy { $0.counterparty == nil && $0.importBatchID == nil && $0.attachmentID == nil })
    }
}

@MainActor
final class DirectionPreservationTests: XCTestCase {

    /// Guards the v1.0.31-fielded-data case: real income/neutral rows written with
    /// the current schema must survive a close + reopen (i.e. the optional-backed
    /// storage round-trips non-`.expense` values, not just the default).
    func testIncomeAndNeutralSurviveCloseAndReopen() throws {
        let url = try freshStoreURL("dir-preserve")
        let incomeID = UUID(), neutralID = UUID(), expenseID = UUID()

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Transaction(id: incomeID, amount: 100, currency: .ron, context: .work,
                                   descriptionText: "salariu", source: .imported, direction: .income))
            ctx.insert(Transaction(id: neutralID, amount: 200, currency: .ron, context: .work,
                                   descriptionText: "transfer", source: .imported, direction: .neutral))
            ctx.insert(Transaction(id: expenseID, amount: 300, currency: .ron, context: .personal,
                                   descriptionText: "alimente", source: .manual, direction: .expense))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let ctx = container.mainContext
        let rows = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first { $0.id == incomeID }?.direction, .income)
        XCTAssertEqual(rows.first { $0.id == neutralID }?.direction, .neutral)
        XCTAssertEqual(rows.first { $0.id == expenseID }?.direction, .expense)
    }
}
