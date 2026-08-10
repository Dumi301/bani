import XCTest
import SwiftData
@testable import Bani

/// Part A card-contract compliance — the review flow. "Unreviewed" is derived
/// (auto-logged rows with no `DecisionRecord`), and each resolution writes exactly
/// one record feeding `TrustEngine`, exactly like a voice card. Discard is a real
/// delete with a restorable Undo.
@MainActor
final class AutoLogReviewTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        // Strongly retain the container via ModelContext(container) — the proven
        // idiom; `.mainContext` on a throwaway container dangles (native crash).
        ModelContext(try ImportTestSupport.inMemoryContainer())
    }

    private func records(_ ctx: ModelContext) -> [DecisionRecord] {
        (try? ctx.fetch(FetchDescriptor<DecisionRecord>())) ?? []
    }
    private func transactions(_ ctx: ModelContext) -> [Transaction] {
        (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
    }

    func testUnreviewedCountExcludesVoiceAndReviewed() throws {
        let ctx = try makeContext()
        _ = try AutoLogWriter.log(AutoLogPayload(amountText: "10", merchant: "A"), in: ctx)
        _ = try AutoLogWriter.log(AutoLogPayload(amountText: "20", merchant: "B"), in: ctx)
        ctx.insert(Transaction(amount: 30, currency: .ron, context: .personal, descriptionText: "voce", source: .voice))
        try ctx.save()

        XCTAssertEqual(AutoLogReview.unreviewedCount(in: ctx), 2, "only unreviewed auto-logged rows count")
    }

    func testConfirmWritesRecordAndMarksReviewed() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "10", merchant: "A"), in: ctx)
        XCTAssertEqual(AutoLogReview.unreviewedCount(in: ctx), 1)

        AutoLogReview.confirm(tx, in: ctx)

        let recs = records(ctx)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.transactionID, tx.id)
        XCTAssertEqual(recs.first?.outcome, .confirmedExplicit)
        XCTAssertEqual(AutoLogReview.unreviewedCount(in: ctx), 0, "a confirmed row is reviewed")
    }

    func testEditWritesCorrectedRecordWithChangedFields() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "10", merchant: "Zzq Unknown"), in: ctx)
        XCTAssertEqual(tx.category, .other)

        var edit = AutoLogReview.Edit(from: tx)
        edit.amount = Decimal(99)
        edit.categoryRef = .preset(.groceries)
        AutoLogReview.applyEdit(tx, to: edit, in: ctx)

        // The transaction mutated.
        XCTAssertEqual(tx.amount, Decimal(99))
        XCTAssertEqual(tx.categoryRef, .preset(.groceries))

        // Exactly one corrected record with the right fields + the ORIGINAL guess.
        let recs = records(ctx)
        XCTAssertEqual(recs.count, 1)
        let rec = try XCTUnwrap(recs.first)
        XCTAssertEqual(rec.outcome, .corrected)
        XCTAssertTrue(rec.correctedFields.contains(.amount))
        XCTAssertTrue(rec.correctedFields.contains(.category))
        XCTAssertEqual(rec.guessedCategory, .other, "record scores the ORIGINAL guess, not the correction")
        XCTAssertEqual(AutoLogReview.unreviewedCount(in: ctx), 0)
    }

    func testEditWithNoChangesRecordsConfirmation() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "10", merchant: "A"), in: ctx)
        AutoLogReview.applyEdit(tx, to: AutoLogReview.Edit(from: tx), in: ctx)
        let rec = try XCTUnwrap(records(ctx).first)
        XCTAssertEqual(rec.outcome, .confirmedExplicit)
        XCTAssertTrue(rec.correctedFields.isEmpty)
    }

    func testDiscardDeletesAndRecordsDiscarded() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "10", merchant: "A"), in: ctx)
        let id = tx.id

        let discarded = AutoLogReview.discard(tx, in: ctx)

        XCTAssertTrue(transactions(ctx).isEmpty, "discard is a real delete")
        let rec = try XCTUnwrap(records(ctx).first)
        XCTAssertEqual(rec.outcome, .discarded)
        XCTAssertNil(rec.transactionID)
        XCTAssertEqual(AutoLogReview.unreviewedCount(in: ctx), 0)

        // Undo restores the transaction (same id, unreviewed again) and drops the record.
        AutoLogReview.restore(discarded, in: ctx)
        XCTAssertEqual(transactions(ctx).count, 1)
        XCTAssertEqual(transactions(ctx).first?.id, id)
        XCTAssertTrue(records(ctx).isEmpty, "undo removes the discard record")
        XCTAssertEqual(AutoLogReview.unreviewedCount(in: ctx), 1)
    }
}
