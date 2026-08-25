import XCTest
import SwiftData
@testable import Bani

/// v1.2b "Loans" — proves the three frozen-seam additions are migration-safe on a
/// REAL on-disk store (write in the old shape → close → reopen under the new
/// schema), the one class of change that can destroy user data:
///   • `Transaction.loanID` — optional additive attribute (the proven-safe pattern;
///     NO non-optional additions — the direction-crash lesson is law).
///   • `ScheduledItem.loanID` — same optional-additive discipline.
///   • new entity `Loan`.
///
/// A store written BEFORE `loanID` / `Loan` existed reopens under the new schema
/// with every row readable, both `loanID`s nil, zero data loss; and a full
/// round-trip of a loan + its loan-tagged transaction + scheduled item persists,
/// closes, reopens, intact.

/// The pre-loans shape of `Transaction`: every current column EXCEPT `loanID`.
/// Nested in an enum so its SwiftData entity name stays `"Transaction"` (the same
/// on-disk table) — the standard versioned-schema idiom (mirrors `LegacyStoreV36`).
private enum LegacyStoreV37 {
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
        @Attribute(originalName: "direction") private var directionStored: TransactionDirection?
        var counterparty: String?
        var attachmentID: UUID?
        var importBatchID: UUID?
        var projectID: UUID?
        var createdAt: Date

        init(id: UUID = UUID(), amount: Decimal, currency: Currency, context: TransactionContext,
             descriptionText: String, source: TransactionSource,
             direction: TransactionDirection = .expense, counterparty: String? = nil,
             projectID: UUID? = nil, date: Date = .now, createdAt: Date = .now) {
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
            self.attachmentID = nil
            self.importBatchID = nil
            self.projectID = projectID
            self.createdAt = createdAt
        }
    }

    /// The pre-loans shape of `ScheduledItem`: every current column EXCEPT `loanID`
    /// (it already carries the v2 recurrence columns).
    @Model final class ScheduledItem {
        var id: UUID
        var direction: ScheduledDirection
        var amount: Decimal
        var currency: Currency
        var title: String
        var descriptionText: String
        var counterparty: String?
        var dueDate: Date
        var projectID: UUID?
        var status: ScheduledStatus
        var linkedTransactionID: UUID?
        var recurrenceRaw: String?
        var seriesID: UUID?
        var createdAt: Date

        init(id: UUID = UUID(), direction: ScheduledDirection, amount: Decimal, currency: Currency,
             title: String, counterparty: String? = nil, dueDate: Date, projectID: UUID? = nil,
             status: ScheduledStatus = .pending, createdAt: Date = .now) {
            self.id = id
            self.direction = direction
            self.amount = amount
            self.currency = currency
            self.title = title
            self.descriptionText = ""
            self.counterparty = counterparty
            self.dueDate = dueDate
            self.projectID = projectID
            self.status = status
            self.linkedTransactionID = nil
            self.recurrenceRaw = nil
            self.seriesID = nil
            self.createdAt = createdAt
        }
    }
}

private func freshStoreURL(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bani-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("store.sqlite")
}

/// The current app's full model set (mirrors `BaniModelContainer.schema`), now
/// including the v1.2b `Loan` entity.
private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        Project.self, ScheduledItem.self, Loan.self,
        configurations: ModelConfiguration(url: url)
    )
}

@MainActor
final class LoanMigrationTests: XCTestCase {

    /// A pre-loans store (no `loanID` columns, no `Loan` table) reopens under the
    /// new schema: every row readable, both `loanID`s nil, prior fields intact.
    func testPreLoanStoreReopensWithLoanIDNilAndNoDataLoss() throws {
        let url = try freshStoreURL("loan-legacy")
        let txID = UUID(), itemID = UUID()
        let projectID = UUID()
        let due = Date(timeIntervalSince1970: 1_770_000_000)

        // 1. Write rows in the pre-loans shape. Scoped so the container closes.
        do {
            let container = try ModelContainer(
                for: LegacyStoreV37.Transaction.self, LegacyStoreV37.ScheduledItem.self,
                configurations: ModelConfiguration(url: url)
            )
            let ctx = container.mainContext
            ctx.insert(LegacyStoreV37.Transaction(id: txID, amount: 6000, currency: .ron, context: .work,
                                                  descriptionText: "chirie primită", source: .imported,
                                                  direction: .income, counterparty: "Ion", projectID: projectID))
            ctx.insert(LegacyStoreV37.ScheduledItem(id: itemID, direction: .outgoing, amount: 2500, currency: .ron,
                                                    title: "Materiale", counterparty: "Dedeman", dueDate: due,
                                                    projectID: projectID))
            try ctx.save()
        }

        // 2. Reopen under the CURRENT schema (adds loanID columns + Loan table).
        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txs.count, 1, "the legacy transaction must migrate")
        let tx = try XCTUnwrap(txs.first)
        XCTAssertNil(tx.loanID, "migrated transaction's loanID must be nil")
        XCTAssertEqual(tx.direction, .income, "prior direction preserved")
        XCTAssertEqual(tx.counterparty, "Ion")
        XCTAssertEqual(tx.projectID, projectID, "prior projectID preserved")

        let items = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        XCTAssertEqual(items.count, 1, "the legacy scheduled item must migrate")
        let item = try XCTUnwrap(items.first)
        XCTAssertNil(item.loanID, "migrated scheduled item's loanID must be nil")
        XCTAssertEqual(item.recurrence, .none, "nil recurrenceRaw still reads .none")
        XCTAssertNil(item.seriesID)
        XCTAssertEqual(item.amount, 2500)
        XCTAssertEqual(item.projectID, projectID)

        // The new Loan table exists and is empty on a migrated store.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Loan>()), 0)
    }

    /// Round-trip: a `Loan`, a loan-tagged `Transaction`, and a loan-tagged
    /// `ScheduledItem` persist, close, reopen, and stay intact + linked.
    func testLoanAndLoanTaggedRowsRoundTrip() throws {
        let url = try freshStoreURL("loan-roundtrip")
        let loanID = UUID(), txID = UUID(), itemID = UUID()
        let start = Date(timeIntervalSince1970: 1_765_000_000)
        let due = Date(timeIntervalSince1970: 1_770_000_000)

        do {
            let container = try currentContainer(at: url)
            let ctx = container.mainContext
            ctx.insert(Loan(id: loanID, name: "Credit BCR", lender: "BCR", kind: .bank, principal: 100_000,
                            currency: .ron, annualRatePercent: Decimal(string: "7.9"), startDate: start,
                            termMonths: 240, projectID: UUID()))
            ctx.insert(Transaction(id: txID, amount: 658, currency: .ron, context: .work,
                                   descriptionText: "dobândă", source: .manual, direction: .expense,
                                   loanID: loanID))
            ctx.insert(ScheduledItem(id: itemID, direction: .outgoing, amount: 900, currency: .ron,
                                     title: "Rată credit", dueDate: due, status: .pending,
                                     recurrence: .none, seriesID: UUID(), loanID: loanID))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let loan = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Loan>()).first)
        XCTAssertEqual(loan.id, loanID)
        XCTAssertEqual(loan.kind, .bank)
        XCTAssertEqual(loan.principal, 100_000)
        XCTAssertEqual(loan.annualRatePercent, Decimal(string: "7.9"))
        XCTAssertEqual(loan.termMonths, 240)
        XCTAssertEqual(loan.status, .active)

        let tx = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(tx.loanID, loanID, "the transaction must still point at its loan after reopen")

        let item = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ScheduledItem>()).first)
        XCTAssertEqual(item.loanID, loanID, "the scheduled item must still point at its loan after reopen")
    }

    /// Enum raw values are stable — SwiftData persists the rawValue, so these must
    /// never drift (a rename would orphan every stored loan row).
    func testLoanEnumRawValuesStable() {
        XCTAssertEqual(LoanKind.bank.rawValue, "bank")
        XCTAssertEqual(LoanKind.investor.rawValue, "investor")
        XCTAssertEqual(LoanStatus.active.rawValue, "active")
        XCTAssertEqual(LoanStatus.closed.rawValue, "closed")
    }
}
