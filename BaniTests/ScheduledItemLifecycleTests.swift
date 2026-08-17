import XCTest
import SwiftData
@testable import Bani

/// v1.2a — the scheduled-money lifecycle: create → overdue computation → mark-done
/// (creates a linked `Transaction` with the mapped direction + project) → undo
/// (restores pending, deletes the transaction). The card contract's terminal state
/// always lands in a persisted transaction.
@MainActor
final class ScheduledItemLifecycleTests: XCTestCase {

    /// Returns the container (NOT just its context) so the caller retains it for
    /// the test's lifetime — a `ModelContext` whose container has deallocated is
    /// dangling and crashes on insert/save.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, ScheduledItem.self, Project.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testOverdueComputation() {
        let now = Date()
        let past = ScheduledItem(direction: .outgoing, amount: 100, currency: .ron, title: "t",
                                 dueDate: now.addingTimeInterval(-86_400))
        XCTAssertTrue(past.isOverdue(asOf: now))

        let future = ScheduledItem(direction: .outgoing, amount: 100, currency: .ron, title: "t",
                                   dueDate: now.addingTimeInterval(86_400))
        XCTAssertFalse(future.isOverdue(asOf: now))

        future.status = .done
        XCTAssertFalse(future.isOverdue(asOf: now), "a done item is never overdue")
    }

    func testMarkDoneCreatesLinkedTransactionWithMappedDirectionAndProject() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let projectID = UUID()
        let outgoing = ScheduledItem(direction: .outgoing, amount: 6000, currency: .ron,
                                     title: "Plată Ion", counterparty: "Ion", dueDate: Date(), projectID: projectID)
        ctx.insert(outgoing)
        try ctx.save()

        let tx = ScheduledItemStore.markDone(outgoing, in: ctx)
        XCTAssertEqual(outgoing.status, .done)
        XCTAssertEqual(outgoing.linkedTransactionID, tx.id)
        XCTAssertEqual(tx.direction, .expense, "outgoing → expense")
        XCTAssertEqual(tx.projectID, projectID)
        XCTAssertEqual(tx.amount, 6000)
        XCTAssertEqual(tx.counterparty, "Ion")

        let incoming = ScheduledItem(direction: .incoming, amount: 12000, currency: .ron,
                                     title: "Avans", dueDate: Date(), projectID: projectID)
        ctx.insert(incoming)
        let tx2 = ScheduledItemStore.markDone(incoming, in: ctx)
        XCTAssertEqual(tx2.direction, .income, "incoming → income")
        XCTAssertEqual(tx2.projectID, projectID)
    }

    func testUndoDoneRestoresPendingAndDeletesTransaction() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let item = ScheduledItem(direction: .outgoing, amount: 500, currency: .ron, title: "t", dueDate: Date())
        ctx.insert(item)
        try ctx.save()

        let tx = ScheduledItemStore.markDone(item, in: ctx)
        let txID = tx.id
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == txID })), 1)

        ScheduledItemStore.undoDone(item, in: ctx)
        XCTAssertEqual(item.status, .pending)
        XCTAssertNil(item.linkedTransactionID)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == txID })), 0,
                       "undo deletes the linked transaction")
    }
}
