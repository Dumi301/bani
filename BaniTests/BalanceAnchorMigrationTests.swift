import XCTest
import SwiftData
@testable import Bani

/// v2 "Balance anchoring / reconciliation" — proves the ONE schema change (a new
/// `BalanceAnchor` entity, zero field additions on any existing entity) is
/// migration-safe on a REAL on-disk store: a store written BEFORE the anchor table
/// existed reopens under the new schema with every row readable and the new table
/// empty; and a full round-trip of an anchor persists, closes, reopens, intact.
///
/// No existing entity gains a field (the additive-optional law is satisfied
/// vacuously here — there is nothing to backfill), so the direction-crash class of
/// bug (`Bani-2026-08-02`) cannot apply; this test pins the additive-entity path,
/// mirroring `LoanMigrationTests` for `Loan`.
@MainActor
final class BalanceAnchorMigrationTests: XCTestCase {

    private func freshStoreURL(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bani-anchor-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    /// The pre-anchor schema: the existing app entities, WITHOUT `BalanceAnchor`.
    private func legacyContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
            CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
            Project.self, ScheduledItem.self, Loan.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    /// The post-anchor schema: the same set PLUS the new `BalanceAnchor` entity.
    private func currentContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
            CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
            Project.self, ScheduledItem.self, Loan.self, BalanceAnchor.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    /// A pre-anchor store (no `BalanceAnchor` table) reopens under the new schema:
    /// existing rows intact, the new table present and empty, zero data loss.
    func testPreAnchorStoreReopensCleanWithEmptyAnchorTable() throws {
        let url = try freshStoreURL("legacy")
        let txID = UUID()
        let projectID = UUID()

        // 1. Write existing-shape data under the pre-anchor schema. Scoped so the
        //    container closes before reopen.
        do {
            let container = try legacyContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Transaction(id: txID, amount: 4200, currency: .ron, context: .work,
                                   descriptionText: "chirie", source: .manual,
                                   direction: .income, projectID: projectID))
            try ctx.save()
        }

        // 2. Reopen under the CURRENT schema (adds the BalanceAnchor table).
        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txs.count, 1, "the legacy transaction must migrate")
        let tx = try XCTUnwrap(txs.first)
        XCTAssertEqual(tx.amount, 4200, "prior amount preserved")
        XCTAssertEqual(tx.direction, .income, "prior direction preserved")
        XCTAssertEqual(tx.projectID, projectID, "prior projectID preserved")

        // The new anchor table exists and is empty on a migrated store.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BalanceAnchor>()), 0)
    }

    /// Round-trip: a `BalanceAnchor` (including a negative recorded drift and a note)
    /// persists, closes, reopens, and stays intact.
    func testBalanceAnchorRoundTrips() throws {
        let url = try freshStoreURL("roundtrip")
        let anchorID = UUID()
        let anchoredAt = Date(timeIntervalSince1970: 1_770_000_000)

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(BalanceAnchor(id: anchorID, amount: Decimal(string: "12345.67")!, currency: .eur,
                                     anchoredAt: anchoredAt, driftAtAnchor: -50, note: "opening balance"))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let anchor = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BalanceAnchor>()).first)
        XCTAssertEqual(anchor.id, anchorID)
        XCTAssertEqual(anchor.amount, Decimal(string: "12345.67"))
        XCTAssertEqual(anchor.currency, .eur, "currency (stored as its rawValue) survives")
        XCTAssertEqual(anchor.anchoredAt, anchoredAt)
        XCTAssertEqual(anchor.driftAtAnchor, -50, "the recorded drift-at-time survives, sign intact")
        XCTAssertEqual(anchor.note, "opening balance")
    }
}
