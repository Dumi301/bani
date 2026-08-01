import XCTest
import SwiftData
@testable import Bani

/// The SwiftData execution path: batch import → undo round-trip (rows gone, batch
/// gone), the cancel-mid-import "never half-visible" invariant, and the
/// create-custom-category decision resolving to a real id.
@MainActor
final class ImportBatchTests: XCTestCase {

    private func makeRows(_ n: Int) -> [ParsedImportRow] {
        (0..<n).map { i in
            let d = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: (i % 28) + 1))!
            let amount = Decimal(i + 1)
            let desc = "row \(i)"
            return ParsedImportRow(
                date: d, amount: amount, currency: .ron, descriptionText: desc,
                context: .personal, categorySource: .byDescription, sourceRow: i + 2,
                fingerprint: ImportFingerprint.fingerprint(date: d, amount: amount, description: desc)
            )
        }
    }

    private func importedTransactions(in container: ModelContainer) -> [Transaction] {
        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.filter { $0.source == .imported }
    }

    private func batchCount(in container: ModelContainer) -> Int {
        let ctx = ModelContext(container)
        return (try? ctx.fetchCount(FetchDescriptor<ImportBatch>())) ?? 0
    }

    func testImportThenUndoRoundTrip() async throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let runner = ImportRunner(modelContainer: container)
        let outcome = await runner.run(
            rows: makeRows(3), fileName: "sample.csv", contextChoice: "personal",
            notes: "", skippedCount: 1, decisions: [:], onProgress: { _ in }
        )

        guard case let .completed(batchID, imported) = outcome else { return XCTFail("expected completed") }
        XCTAssertEqual(imported, 3)

        let txs = importedTransactions(in: container)
        XCTAssertEqual(txs.count, 3)
        XCTAssertTrue(txs.allSatisfy { $0.importBatchID == batchID })
        XCTAssertTrue(txs.allSatisfy { $0.rawTranscript == nil })   // scope guard E
        XCTAssertTrue(txs.allSatisfy { $0.category == .other })     // byDescription, no rules → .other
        XCTAssertEqual(batchCount(in: container), 1)

        let ctx = ModelContext(container)
        let removed = ImportBatchStore.undo(batchID: batchID, in: ctx)
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(importedTransactions(in: container).count, 0)   // rows gone
        XCTAssertEqual(batchCount(in: container), 0)                    // batch gone
    }

    func testCancelLeavesNoPartialImport() async throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let runner = ImportRunner(modelContainer: container)
        let task = Task {
            await runner.run(
                rows: self.makeRows(600), fileName: "big.csv", contextChoice: "personal",
                notes: "", skippedCount: 0, decisions: [:], onProgress: { _ in }
            )
        }
        task.cancel()
        let outcome = await task.value
        switch outcome {
        case .cancelled:
            // Rolled back — nothing half-visible.
            XCTAssertEqual(importedTransactions(in: container).count, 0)
            XCTAssertEqual(batchCount(in: container), 0)
        case .completed(_, let n):
            // Finished before the cancel landed — the whole import is present.
            XCTAssertEqual(n, 600)
            XCTAssertEqual(importedTransactions(in: container).count, 600)
        }
    }

    func testCreateCustomCategoryDecisionResolves() async throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let runner = ImportRunner(modelContainer: container)
        let d = Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 2))!
        let row = ParsedImportRow(
            date: d, amount: 30, currency: .ron, descriptionText: "gift",
            context: .personal, categorySource: .columnValue("Cadouri"), sourceRow: 2, fingerprint: "fp"
        )
        let decisions: [String: ImportCategoryDecision] = [
            Categorizer.normalize("Cadouri"): .create(name: "Cadouri", symbolName: "gift.fill", colorIndex: 2)
        ]
        let outcome = await runner.run(
            rows: [row], fileName: "f.csv", contextChoice: "personal",
            notes: "", skippedCount: 0, decisions: decisions, onProgress: { _ in }
        )
        guard case .completed = outcome else { return XCTFail("expected completed") }

        let ctx = ModelContext(container)
        let customs = (try? ctx.fetch(FetchDescriptor<CustomCategory>())) ?? []
        XCTAssertEqual(customs.count, 1)
        XCTAssertEqual(customs.first?.name, "Cadouri")
        XCTAssertEqual(importedTransactions(in: container).first?.customCategoryID, customs.first?.id)
    }
}
