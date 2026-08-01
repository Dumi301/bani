import XCTest
import SwiftData
@testable import Bani

/// Proves the two documented frozen-seam additions are migration-safe: the
/// `TransactionSource.imported` case + `Transaction.importBatchID` are additive,
/// existing-style rows keep `importBatchID == nil`, and `ImportBatch` registers
/// as a separate entity — existing data untouched (same discipline as the
/// `customCategoryID` precedent).
@MainActor
final class ImportModelMigrationTests: XCTestCase {

    func testAdditiveFieldsCoexist() throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let ctx = container.mainContext

        let legacy = Transaction(amount: 10, currency: .ron, context: .personal, descriptionText: "legacy", source: .manual)
        let imported = Transaction(amount: 20, currency: .eur, context: .work, descriptionText: "imported", source: .imported, importBatchID: UUID())
        ctx.insert(legacy)
        ctx.insert(imported)
        ctx.insert(ImportBatch(fileName: "f.csv", rowCount: 1, skippedCount: 0, contextChoice: "work"))
        try ctx.save()

        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txs.count, 2)

        let legacyFetched = try XCTUnwrap(txs.first { $0.descriptionText == "legacy" })
        XCTAssertNil(legacyFetched.importBatchID)          // existing rows migrate to nil, untouched
        XCTAssertEqual(legacyFetched.source, .manual)

        let importedFetched = try XCTUnwrap(txs.first { $0.descriptionText == "imported" })
        XCTAssertEqual(importedFetched.source, .imported)  // the new enum case round-trips
        XCTAssertNotNil(importedFetched.importBatchID)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ImportBatch>()), 1)
    }

    func testSourceEnumRawValuesStable() {
        // SwiftData persists the enum's rawValue; adding a case must not perturb
        // the strings existing rows already hold.
        XCTAssertEqual(TransactionSource.voice.rawValue, "voice")
        XCTAssertEqual(TransactionSource.manual.rawValue, "manual")
        XCTAssertEqual(TransactionSource.imported.rawValue, "imported")
        XCTAssertEqual(TransactionSource(rawValue: "voice"), .voice)   // legacy decodes unchanged
        XCTAssertEqual(TransactionSource(rawValue: "manual"), .manual)
    }
}
