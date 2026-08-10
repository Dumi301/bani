import XCTest
import SwiftData
@testable import Bani

/// v1.1 Auto-Logging — the additive `.autoLogged` `TransactionSource` case must be
/// migration-safe: a store written with only the pre-existing cases
/// (`voice`/`manual`/`imported`) still decodes cleanly, AND the new case
/// round-trips. `TransactionSource` persists as its `String` rawValue, so adding a
/// case only widens the valid set — but post-direction-lesson paranoia is
/// mandatory, so this is proven on a REAL on-disk store (close + reopen), the one
/// class of change that can destroy user data.

private func freshStoreURL(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bani-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("store.sqlite")
}

private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        configurations: ModelConfiguration(url: url)
    )
}

@MainActor
final class TransactionSourceMigrationTests: XCTestCase {

    /// A store holding only the OLD source cases decodes clean on reopen — adding
    /// `.autoLogged` does not disturb the stored "voice"/"manual"/"imported" strings.
    func testOldSourceCasesDecodeCleanAfterAddingAutoLogged() throws {
        let url = try freshStoreURL("src-old")
        let voiceID = UUID(), manualID = UUID(), importedID = UUID()

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Transaction(id: voiceID, amount: 10, currency: .ron, context: .personal,
                                   descriptionText: "voce", source: .voice))
            ctx.insert(Transaction(id: manualID, amount: 20, currency: .eur, context: .work,
                                   descriptionText: "manual", source: .manual))
            ctx.insert(Transaction(id: importedID, amount: 30, currency: .ron, context: .personal,
                                   descriptionText: "import", source: .imported))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let rows = try container.mainContext.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, 3, "old-case rows must migrate into the current schema")
        XCTAssertEqual(rows.first { $0.id == voiceID }?.source, .voice)
        XCTAssertEqual(rows.first { $0.id == manualID }?.source, .manual)
        XCTAssertEqual(rows.first { $0.id == importedID }?.source, .imported)
        XCTAssertFalse(rows.contains { $0.source == .autoLogged }, "no row should spuriously become .autoLogged")
    }

    /// A `.autoLogged` row survives close + reopen with its value intact.
    func testAutoLoggedRoundTrips() throws {
        let url = try freshStoreURL("src-auto")
        let autoID = UUID()

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Transaction(id: autoID, amount: 45, currency: .ron, context: .personal,
                                   descriptionText: "MEGA IMAGE", source: .autoLogged, direction: .expense))
            // Mixed store: an old-case row alongside the new one must also survive.
            ctx.insert(Transaction(amount: 12, currency: .ron, context: .work,
                                   descriptionText: "voce", source: .voice))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let rows = try container.mainContext.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, 2)
        let auto = rows.first { $0.id == autoID }
        XCTAssertEqual(auto?.source, .autoLogged)
        XCTAssertEqual(auto?.direction, .expense)
        XCTAssertEqual(rows.filter { $0.source == .voice }.count, 1)
    }
}
