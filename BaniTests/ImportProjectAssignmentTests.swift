import XCTest
import SwiftData
@testable import Bani

/// v1.2a — the batch-level import project picker: whatever project the understanding
/// report carries is applied to EVERY committed row on Confirm (per-row overrides
/// are out of scope).
@MainActor
final class ImportProjectAssignmentTests: XCTestCase {

    private func draft(_ i: Int, context: TransactionContext) -> DraftTransaction {
        let date = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: (i % 28) + 1))!
        return DraftTransaction(
            date: date, amount: Decimal(i + 1), currency: .ron, direction: .expense,
            descriptionText: "row \(i)", context: context, category: .byDescription, sourceRow: i + 2
        )
    }

    func testImportedBatchCarriesChosenProjectID() async throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let projectID = UUID()
        let items = (0..<3).map {
            CommitItem(draft: draft($0, context: .work), context: .work, attachment: nil, projectID: projectID)
        }

        let runner = ImportCommitRunner(modelContainer: container)
        let outcome = await runner.commit(
            items: items, fileName: "extras.csv", contextChoice: "work",
            notes: "", skippedCount: 0, onProgress: { _ in }
        )
        guard case let .completed(_, imported) = outcome else { return XCTFail("expected completed") }
        XCTAssertEqual(imported, 3)

        let ctx = ModelContext(container)
        let txs = (try ctx.fetch(FetchDescriptor<Transaction>())).filter { $0.source == .imported }
        XCTAssertEqual(txs.count, 3)
        XCTAssertTrue(txs.allSatisfy { $0.projectID == projectID },
                      "every committed row carries the chosen batch project")
    }

    func testNoBatchProjectLeavesRowsUnassigned() async throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let items = (0..<2).map {
            CommitItem(draft: draft($0, context: .personal), context: .personal, attachment: nil, projectID: nil)
        }
        let runner = ImportCommitRunner(modelContainer: container)
        _ = await runner.commit(
            items: items, fileName: "f.csv", contextChoice: "personal",
            notes: "", skippedCount: 0, onProgress: { _ in }
        )
        let ctx = ModelContext(container)
        let txs = (try ctx.fetch(FetchDescriptor<Transaction>())).filter { $0.source == .imported }
        XCTAssertEqual(txs.count, 2)
        XCTAssertTrue(txs.allSatisfy { $0.projectID == nil }, "no batch project → rows stay unassigned")
    }

    /// The report defaults its batch project to the last-used project for a
    /// Work-defaulting batch, and to none for a Personal batch — the pure rule the
    /// report-build step applies (`ProjectAssignment.smartDefault`).
    func testDefaultProjectFollowsWorkDefaulting() {
        let id = UUID()
        XCTAssertEqual(ProjectAssignment.smartDefault(context: .work, lastUsedRaw: id.uuidString), id)
        XCTAssertNil(ProjectAssignment.smartDefault(context: .personal, lastUsedRaw: id.uuidString))
    }
}
