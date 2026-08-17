import XCTest
import SwiftData
@testable import Bani

/// v1.2a — an auto-logged (App Intent) payment carries the last-used project when
/// its resolved context is Work, and the review chip's edit corrects the project,
/// updating the transaction AND writing a `.project` correction to the ledger
/// (exactly like the voice card chip).
@MainActor
final class AutoLogProjectAssignmentTests: XCTestCase {

    /// Full app schema in-memory (includes Project — the auto-log clamp fetches it).
    private func makeContainer() throws -> ModelContainer {
        try BaniModelContainer.make(inMemory: true)
    }

    func testWorkAutoLogCarriesLastUsedProjectAndReviewCorrectionUpdatesIt() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let projectID = UUID()
        UserDefaults.standard.set(projectID.uuidString, forKey: "lastUsedProjectID")
        defer { UserDefaults.standard.removeObject(forKey: "lastUsedProjectID") }

        // The last-used project must still exist (the clamp drops dead ids).
        ctx.insert(Project(id: projectID, name: "Proiect Manhattan", colorIndex: 0))
        // Force a Work pre-selection for "Aeroport" (≥3 confirmations, 100%).
        for _ in 0..<3 {
            ContextRuleStore.record(finalContext: .work, description: "Aeroport", merchant: "Aeroport", in: ctx)
        }

        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "120", merchant: "Aeroport"), in: ctx)
        XCTAssertEqual(tx.context, .work, "the resolved context should be Work")
        XCTAssertEqual(tx.projectID, projectID, "a Work auto-log carries the last-used project")

        // Review-chip correction: reassign the project.
        let newProjectID = UUID()
        ctx.insert(Project(id: newProjectID, name: "Renovare", colorIndex: 1))
        var edit = AutoLogReview.Edit(from: tx)
        edit.projectID = newProjectID
        AutoLogReview.applyEdit(tx, to: edit, in: ctx)

        XCTAssertEqual(tx.projectID, newProjectID, "the correction updates the transaction's project")

        let records = DecisionLedger.allRecords(in: ctx).filter { $0.transactionID == tx.id }
        let projectCorrection = records.first { $0.correctedFields.contains(.project) }
        XCTAssertNotNil(projectCorrection, "a project correction writes a DecisionRecord with the .project field")
        XCTAssertEqual(projectCorrection?.outcome, .corrected)
    }

    func testPersonalAutoLogCarriesNoProject() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let projectID = UUID()
        UserDefaults.standard.set(projectID.uuidString, forKey: "lastUsedProjectID")
        defer { UserDefaults.standard.removeObject(forKey: "lastUsedProjectID") }
        ctx.insert(Project(id: projectID, name: "Manhattan", colorIndex: 0))

        // No context rule → resolves to Personal → never project-tagged.
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "50", merchant: "Zzq Unknown"), in: ctx)
        XCTAssertEqual(tx.context, .personal)
        XCTAssertNil(tx.projectID, "a Personal auto-log is never project-tagged")
    }

    func testDeletedLastUsedProjectIsNotAssigned() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        // last-used points at a project that does not exist in the store.
        UserDefaults.standard.set(UUID().uuidString, forKey: "lastUsedProjectID")
        defer { UserDefaults.standard.removeObject(forKey: "lastUsedProjectID") }
        for _ in 0..<3 {
            ContextRuleStore.record(finalContext: .work, description: "Aeroport", merchant: "Aeroport", in: ctx)
        }

        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "120", merchant: "Aeroport"), in: ctx)
        XCTAssertEqual(tx.context, .work)
        XCTAssertNil(tx.projectID, "a dead last-used id is clamped away, never assigned")
    }
}
