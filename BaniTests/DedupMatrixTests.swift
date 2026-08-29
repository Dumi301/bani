import XCTest
import SwiftData
@testable import Bani

/// P8 — cross-source dedup. `TransactionFingerprint` is pure (no SwiftData): the
/// confidence-tier math, tested in isolation from any store/actor.
final class TransactionFingerprintTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_720_000_000)

    private func key(amount: Decimal = 50, currency: Currency = .ron, direction: TransactionDirection = .expense,
                      date: Date? = nil, counterparty: String) -> TransactionFingerprint.Key {
        TransactionFingerprint.Key(amount: amount, currency: currency, direction: direction, date: date ?? day, counterparty: counterparty)
    }

    func testExactRequiresSameDayAndFuzzyCounterpartyMatch() {
        let a = key(counterparty: "MEGA IMAGE")
        let b = key(counterparty: "Mega Image Titan")
        XCTAssertEqual(TransactionFingerprint.confidence(a, b), .exact)
    }

    func testSameDayWithNoCounterpartyMatchIsProbableNotExact() {
        let a = key(counterparty: "Lidl")
        let b = key(counterparty: "Unrelated Text")
        XCTAssertEqual(TransactionFingerprint.confidence(a, b), .probable)
    }

    func testOneDayApartIsProbable() {
        let a = key(date: day, counterparty: "Auchan")
        let b = key(date: day.addingTimeInterval(20 * 60 * 60), counterparty: "Auchan")
        XCTAssertEqual(TransactionFingerprint.confidence(a, b), .probable)
    }

    func testTwoDaysApartIsNone() {
        let a = key(date: day, counterparty: "Auchan")
        let b = key(date: day.addingTimeInterval(2 * 24 * 60 * 60), counterparty: "Auchan")
        XCTAssertEqual(TransactionFingerprint.confidence(a, b), .none)
    }

    func testMismatchedAmountIsNone() {
        let a = key(amount: 50, counterparty: "Lidl")
        let b = key(amount: 51, counterparty: "Lidl")
        XCTAssertEqual(TransactionFingerprint.confidence(a, b), .none)
    }

    func testMismatchedDirectionIsNoneEvenWithEverythingElseMatching() {
        let a = key(direction: .expense, counterparty: "Lidl")
        let b = key(direction: .income, counterparty: "Lidl")
        XCTAssertEqual(TransactionFingerprint.confidence(a, b), .none)
    }

    func testCounterpartyFuzzyMatchIsPrefixBasedAfterNormalization() {
        // A genuine prefix match after fold+lowercase.
        XCTAssertTrue(TransactionFingerprint.counterpartyFuzzyMatches("OMV", "OMV Petrom"))
        // Diacritics fold before the prefix check ("Benzină" → "benzina").
        XCTAssertTrue(TransactionFingerprint.counterpartyFuzzyMatches("Benzină", "Benzina Auchan"))
        // A SUFFIX (not a prefix) does NOT match — this is a prefix match, not a
        // substring/contains match (per spec: "prefix match").
        XCTAssertFalse(TransactionFingerprint.counterpartyFuzzyMatches("Bolt", "Taxi Bolt"))
        XCTAssertFalse(TransactionFingerprint.counterpartyFuzzyMatches("", ""))
        XCTAssertFalse(TransactionFingerprint.counterpartyFuzzyMatches("Lidl", "Auchan"))
    }
}

/// P8 gate: `DedupMatrixTests` — the pairwise collision matrix (voice × autolog
/// intent × autolog share × import), same-source exclusion, the reconciliation/
/// loan exclusion rules, merge/keep-both resolution, and the import batch-advisory
/// path. Extends (never breaks) `DedupCollisionTests`, which covers the
/// PRE-EXISTING import-fingerprint dedup (`ImportBatchStore` /
/// `ImportFingerprint`) — a separate, narrower mechanism this run does not touch.
@MainActor
final class DedupMatrixTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ImportTestSupport.inMemoryContainer()
    }

    private func makeContext() throws -> ModelContext {
        // Strongly retain the container via ModelContext(container) — the proven
        // idiom; `.mainContext` on a throwaway container dangles (native crash).
        ModelContext(try makeContainer())
    }

    @discardableResult
    private func saveVoice(amount: Decimal, currency: Currency = .ron, description: String, date: Date,
                            direction: TransactionDirection = .expense, in ctx: ModelContext) -> Transaction {
        let parsed = ParsedTransaction(amount: amount, currency: currency, descriptionText: description)
        return saveVoiceTransaction(parsed: parsed, transcript: description, context: .personal, date: date, direction: direction, into: ctx)!
    }

    @discardableResult
    private func saveManual(amount: Decimal, currency: Currency = .ron, description: String, date: Date,
                             direction: TransactionDirection = .expense, in ctx: ModelContext) -> Transaction {
        let tx = Transaction(amount: amount, currency: currency, context: .personal, descriptionText: description,
                              date: date, source: .manual, direction: direction)
        ctx.insert(tx)
        try? ctx.save()
        DedupService.flagIfDuplicate(tx, in: ctx)
        return tx
    }

    @discardableResult
    private func commitImportRow(amount: Decimal, description: String, date: Date, in container: ModelContainer) async throws -> Transaction {
        let draft = DraftTransaction(date: date, amount: amount, currency: .ron, direction: .expense,
                                     descriptionText: description, context: .personal, category: .uncategorized, sourceRow: 1)
        let item = CommitItem(draft: draft, context: .personal, attachment: nil)
        let runner = ImportCommitRunner(modelContainer: container)
        _ = await runner.commit(items: [item], fileName: "f.csv", contextChoice: "personal", notes: "", skippedCount: 0, onProgress: { _ in })
        let all = (try? ModelContext(container).fetch(FetchDescriptor<Transaction>())) ?? []
        return try XCTUnwrap(all.first { $0.source == .imported && $0.descriptionText == description && $0.amount == amount })
    }

    private func records(_ ctx: ModelContext) -> [DecisionRecord] {
        (try? ctx.fetch(FetchDescriptor<DecisionRecord>())) ?? []
    }

    /// A bank-feed row shaped EXACTLY like `BankSyncService.sync()`'s insert:
    /// `source == .autoLogged`, `rawTranscript` built by the real
    /// `BankSyncMapper.rawTranscript(for:)` (so the `[bank]` prefix + embedded
    /// bank-key marker come from the actual P9 mapper, not a hand-rolled guess).
    @discardableResult
    private func saveBank(amount: Decimal, currency: Currency = .ron, description: String, counterparty: String? = nil,
                           date: Date, direction: TransactionDirection = .expense, bankKey: String, in ctx: ModelContext) -> Transaction {
        let draft = BankDraft(amount: amount, direction: direction, currency: currency, counterparty: counterparty,
                              descriptionText: description, date: date, bankKey: bankKey, rawText: description)
        let tx = Transaction(amount: amount, currency: currency, context: .personal, descriptionText: description,
                             date: date, rawTranscript: BankSyncMapper.rawTranscript(for: draft), source: .autoLogged,
                             direction: direction, counterparty: counterparty)
        ctx.insert(tx)
        try? ctx.save()
        DedupService.flagIfDuplicate(tx, in: ctx)
        return tx
    }

    // MARK: - Pairwise collision matrix (voice × autolog-intent × autolog-share × import)

    func testVoiceCollidesWithAutoLogIntent() throws {
        let ctx = try makeContext()
        let now = Date()
        let voiceTx = saveVoice(amount: 45, description: "Mega Image", date: now, in: ctx)
        let autoTx = try AutoLogWriter.log(
            AutoLogPayload(amountText: "45", currencyCode: "RON", merchant: "Mega Image", date: now, origin: .intent),
            in: ctx
        )
        XCTAssertEqual(autoTx.duplicateOfID, voiceTx.id, "voice log then Apple Pay auto-capture of the same payment must collide")
    }

    func testVoiceCollidesWithAutoLogShare() throws {
        let ctx = try makeContext()
        let now = Date()
        let voiceTx = saveVoice(amount: 45, description: "Mega Image", date: now, in: ctx)
        let shareTx = AutoLogWriter.logShared(
            amount: 45, currency: .ron, descriptionText: "Mega Image", merchant: "Mega Image",
            direction: .expense, rawText: "notificare Mega Image 45 RON", in: ctx
        )
        XCTAssertEqual(shareTx.duplicateOfID, voiceTx.id, "voice log then a shared bank notification of the same payment must collide")
    }

    func testVoiceCollidesWithImport() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let now = Date()
        let voiceTx = saveVoice(amount: 61, description: "OMV Benzina", date: now, in: ctx)
        let importedTx = try await commitImportRow(amount: 61, description: "OMV Benzina", date: now, in: container)
        XCTAssertEqual(importedTx.duplicateOfID, voiceTx.id, "an imported row matching an existing voice entry must be flagged")
    }

    func testAutoLogIntentCollidesWithAutoLogShare() throws {
        let ctx = try makeContext()
        let now = Date()
        let intentTx = try AutoLogWriter.log(
            AutoLogPayload(amountText: "80", currencyCode: "RON", merchant: "Kaufland", date: now, origin: .intent),
            in: ctx
        )
        let shareTx = AutoLogWriter.logShared(
            amount: 80, currency: .ron, descriptionText: "Kaufland", merchant: "Kaufland",
            direction: .expense, rawText: "notificare Kaufland 80 RON", in: ctx
        )
        // Both carry `source == .autoLogged` (the ONE frozen-seam case), but they
        // are logged via DIFFERENT real-world surfaces (Apple Pay vs. a shared
        // notification) — this is the case the raw `TransactionSource` comparison
        // would have wrongly treated as "same source" and silently missed.
        XCTAssertEqual(intentTx.source, .autoLogged)
        XCTAssertEqual(shareTx.source, .autoLogged)
        XCTAssertEqual(shareTx.duplicateOfID, intentTx.id, "Apple Pay auto-capture and a shared notification of the same payment must collide")
    }

    func testAutoLogCollidesWithImport() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let now = Date()
        let autoTx = try AutoLogWriter.log(
            AutoLogPayload(amountText: "22.50", currencyCode: "RON", merchant: "Starbucks", date: now, origin: .intent),
            in: ctx
        )
        let importedTx = try await commitImportRow(amount: Decimal(string: "22.50")!, description: "Starbucks", date: now, in: container)
        XCTAssertEqual(importedTx.duplicateOfID, autoTx.id, "an imported row matching an existing auto-logged payment must be flagged")
    }

    func testShareCollidesWithImport() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let now = Date()
        let shareTx = AutoLogWriter.logShared(
            amount: 15, currency: .ron, descriptionText: "Taxi Bolt", merchant: "Bolt",
            direction: .expense, rawText: "notificare Bolt 15 RON", in: ctx
        )
        let importedTx = try await commitImportRow(amount: 15, description: "Taxi Bolt", date: now, in: container)
        XCTAssertEqual(importedTx.duplicateOfID, shareTx.id, "an imported row matching an existing shared-capture payment must be flagged")
    }

    // MARK: - Same-source pairs NOT flagged

    func testSameSourcePairsNotFlagged() throws {
        let ctx = try makeContext()
        let now = Date()

        // voice+voice, same amount, same day — legit duplicate hand-spoken spend
        // is expected and must never be flagged.
        saveVoice(amount: 33, description: "Parcare Baneasa", date: now, in: ctx)
        let secondVoice = saveVoice(amount: 33, description: "Parcare Baneasa", date: now, in: ctx)
        XCTAssertNil(secondVoice.duplicateOfID, "voice+voice same amount same day is not flagged")

        // manual+manual — same discipline.
        saveManual(amount: 15, description: "Taxi", date: now, in: ctx)
        let secondManual = saveManual(amount: 15, description: "Taxi", date: now, in: ctx)
        XCTAssertNil(secondManual.duplicateOfID, "manual+manual same amount same day is not flagged")

        // autolog-intent + autolog-intent — same origin, not flagged either (the
        // finer `DedupOrigin` still treats two intent captures as one origin).
        _ = try AutoLogWriter.log(AutoLogPayload(amountText: "9", merchant: "Test Café", date: now, origin: .intent), in: ctx)
        let secondIntent = try AutoLogWriter.log(AutoLogPayload(amountText: "9", merchant: "Test Café", date: now, origin: .intent), in: ctx)
        XCTAssertNil(secondIntent.duplicateOfID, "autolog-intent + autolog-intent (same origin) is not flagged")
    }

    // MARK: - Exclusion rules (P4 adjustments, P3 loan slices — never on either side)

    func testLoanSliceIsNeverACandidateAndNeverFlaggedItself() throws {
        let ctx = try makeContext()
        let now = Date()
        let loanID = UUID()
        // Shaped exactly like `LoanStore.bookPayment`'s interest/principal slice.
        let loanTx = Transaction(amount: 200, currency: .ron, context: .work, descriptionText: "Loan interest",
                                 date: now, source: .manual, direction: .expense, loanID: loanID)
        ctx.insert(loanTx)
        try ctx.save()

        // An otherwise-identical manual entry must NOT collide with it.
        let manualTx = saveManual(amount: 200, description: "Loan interest", date: now, in: ctx)
        XCTAssertNil(manualTx.duplicateOfID, "a loan slice is never offered as a dedup candidate, even with a matching shape")

        // And the loan slice is never flagged itself, even if run through the check.
        DedupService.flagIfDuplicate(loanTx, in: ctx)
        XCTAssertNil(loanTx.duplicateOfID, "a loan slice is never flagged as a duplicate itself")
    }

    func testReconciliationAdjustmentIsNeverACandidateAndNeverFlaggedItself() throws {
        let ctx = try makeContext()
        let now = Date()
        // Shaped exactly like `ReconciliationStore.createAdjustmentAndAnchor`'s tx.
        let adjustmentTx = Transaction(amount: 88, currency: .ron, context: .personal,
                                       customCategoryID: ReconciliationCategories.adjustmentCategoryID,
                                       descriptionText: "Balance adjustment", date: now, source: .manual, direction: .income)
        ctx.insert(adjustmentTx)
        try ctx.save()

        let manualTx = saveManual(amount: 88, description: "Balance adjustment", date: now, direction: .income, in: ctx)
        XCTAssertNil(manualTx.duplicateOfID, "a reconciliation adjustment is never offered as a dedup candidate")

        DedupService.flagIfDuplicate(adjustmentTx, in: ctx)
        XCTAssertNil(adjustmentTx.duplicateOfID, "a reconciliation adjustment is never flagged as a duplicate itself")
    }

    // MARK: - Resolution: merge keeps the richer record + writes exactly one DecisionRecord

    func testMergeKeepsRicherFieldsAndWritesCorrectedDecisionRecord() throws {
        let ctx = try makeContext()
        let now = Date()
        let projectID = UUID()

        let voiceTx = saveVoice(amount: 77, description: "Lidl Cluj", date: now, in: ctx)   // earlier createdAt
        let shareTx = AutoLogWriter.logShared(
            amount: 77, currency: .ron, descriptionText: "Lidl", merchant: "Lidl",
            direction: .expense, rawText: "notificare Lidl 77 RON", in: ctx
        )
        shareTx.projectID = projectID
        shareTx.attachmentID = UUID()
        // Force a deterministic createdAt ordering (back-to-back `Date.now` calls
        // are not a reliable enough clock-resolution guarantee to assert on) —
        // `merge` picks the keeper by `createdAt`, so pin it explicitly.
        voiceTx.createdAt = now.addingTimeInterval(-60)
        shareTx.createdAt = now
        try ctx.save()

        XCTAssertEqual(shareTx.duplicateOfID, voiceTx.id, "the later save is flagged against the earlier one")
        let recordsBefore = records(ctx).count
        let originalVoiceTranscript = voiceTx.rawTranscript   // captured BEFORE merge — the keeper must keep its OWN value

        let kept = DedupService.merge(shareTx, in: ctx)

        XCTAssertEqual(kept?.id, voiceTx.id, "the earlier-created transaction keeps its id")
        XCTAssertEqual(kept?.projectID, projectID, "the richer projectID unions onto the keeper")
        XCTAssertNotNil(kept?.attachmentID, "the richer attachment unions onto the keeper")
        XCTAssertEqual(kept?.rawTranscript, originalVoiceTranscript, "the keeper's own non-empty rawTranscript is preserved (not overwritten by the loser's)")

        let remaining = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(remaining.count, 1, "the loser is deleted, never both kept as duplicates")
        XCTAssertNil(remaining.first?.duplicateOfID, "the flag is resolved on merge")

        let recs = records(ctx)
        XCTAssertEqual(recs.count, recordsBefore + 1, "exactly one DecisionRecord is written for the merge")
        XCTAssertEqual(recs.last?.outcome, .corrected)
        XCTAssertTrue(recs.last?.correctedFields.contains(.merge) ?? false, "the merge is recorded via the additive .merge bit")
    }

    // MARK: - L2: merge repoints dangling references before deleting the loser

    /// L2: a container that ALSO registers `ScheduledItem` (absent from
    /// `ImportTestSupport.inMemoryContainer()`, `makeContainer()`'s backing), so
    /// the dangling-reference repoint tests below can plant a linked ScheduledItem
    /// alongside the dedup-relevant types `saveVoice`/`AutoLogWriter.logShared` need.
    private func makeContextWithScheduledItems() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
            CorrectionMemory.self, CustomCategory.self, ImportBatch.self, ScheduledItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testMergeRepointsOtherDuplicateOfIDReferencesToKeeper() throws {
        let ctx = try makeContextWithScheduledItems()
        let now = Date()

        let voiceTx = saveVoice(amount: 77, description: "Lidl Cluj", date: now, in: ctx)   // earlier createdAt, the keeper
        let shareTx = AutoLogWriter.logShared(
            amount: 77, currency: .ron, descriptionText: "Lidl", merchant: "Lidl",
            direction: .expense, rawText: "notificare Lidl 77 RON", in: ctx
        )
        voiceTx.createdAt = now.addingTimeInterval(-60)
        shareTx.createdAt = now
        try ctx.save()
        XCTAssertEqual(shareTx.duplicateOfID, voiceTx.id, "sanity: shareTx (the loser) is flagged against voiceTx (the keeper)")

        // A THIRD, unrelated transaction independently flagged as a duplicate of the
        // LOSER — simulating an earlier, separate P8 flag unrelated to this merge.
        let thirdTx = Transaction(amount: 5, currency: .ron, context: .personal,
                                   descriptionText: "altceva", date: now, source: .manual, direction: .expense)
        ctx.insert(thirdTx)
        thirdTx.duplicateOfID = shareTx.id
        try ctx.save()

        let kept = DedupService.merge(shareTx, in: ctx)
        XCTAssertEqual(kept?.id, voiceTx.id)

        XCTAssertEqual(thirdTx.duplicateOfID, voiceTx.id,
                       "a third row's duplicateOfID is repointed to the keeper, never left dangling on the deleted loser")
    }

    func testMergeRepointsLinkedScheduledItemToKeeper() throws {
        let ctx = try makeContextWithScheduledItems()
        let now = Date()

        let voiceTx = saveVoice(amount: 77, description: "Lidl Cluj", date: now, in: ctx)   // earlier createdAt, the keeper
        let shareTx = AutoLogWriter.logShared(
            amount: 77, currency: .ron, descriptionText: "Lidl", merchant: "Lidl",
            direction: .expense, rawText: "notificare Lidl 77 RON", in: ctx
        )
        voiceTx.createdAt = now.addingTimeInterval(-60)
        shareTx.createdAt = now
        try ctx.save()
        XCTAssertEqual(shareTx.duplicateOfID, voiceTx.id, "sanity: shareTx (the loser) is flagged against voiceTx (the keeper)")

        // A ScheduledItem "mark-done" linked to the LOSER — independent of dedup.
        let item = ScheduledItem(direction: .outgoing, amount: 77, currency: .ron, title: "Chirie",
                                  dueDate: now, status: .done, linkedTransactionID: shareTx.id)
        ctx.insert(item)
        try ctx.save()

        let kept = DedupService.merge(shareTx, in: ctx)
        XCTAssertEqual(kept?.id, voiceTx.id)

        XCTAssertEqual(item.linkedTransactionID, voiceTx.id,
                       "the ScheduledItem's link is repointed to the keeper, never left dangling on the deleted loser")
    }

    func testKeepBothClearsFlagWithoutDeletingAndWritesConfirmedRecord() throws {
        let ctx = try makeContext()
        let now = Date()
        let voiceTx = saveVoice(amount: 20, description: "Cafea", date: now, in: ctx)
        let manualTx = saveManual(amount: 20, description: "Cafea", date: now, in: ctx)
        XCTAssertEqual(manualTx.duplicateOfID, voiceTx.id)

        DedupService.keepBoth(manualTx, in: ctx)

        XCTAssertNil(manualTx.duplicateOfID, "keep-both clears the flag")
        let remaining = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(remaining.count, 2, "keep-both never deletes — both are legitimately separate")
        XCTAssertEqual(records(ctx).last?.outcome, .confirmedExplicit)
    }

    // MARK: - Import batch-advisory path (never row-by-row, never blocks the commit)

    func testImportBatchFlagsOnlyMatchingRowsAndCommitsAllRows() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let now = Date()
        let voiceTx = saveVoice(amount: 61, description: "OMV Benzina", date: now, in: ctx)

        let matchingDraft = DraftTransaction(date: now, amount: 61, currency: .ron, direction: .expense,
                                             descriptionText: "OMV Benzina", context: .personal, category: .uncategorized, sourceRow: 1)
        let freshDraft = DraftTransaction(date: now, amount: 999, currency: .ron, direction: .expense,
                                          descriptionText: "Something new", context: .personal, category: .uncategorized, sourceRow: 2)
        let items = [
            CommitItem(draft: matchingDraft, context: .personal, attachment: nil),
            CommitItem(draft: freshDraft, context: .personal, attachment: nil),
        ]
        let runner = ImportCommitRunner(modelContainer: container)
        let outcome = await runner.commit(items: items, fileName: "f.csv", contextChoice: "personal", notes: "", skippedCount: 0, onProgress: { _ in })
        guard case let .completed(_, imported) = outcome else { return XCTFail("expected completed") }

        // Never blocked, never dropped — BOTH rows commit regardless of the flag.
        XCTAssertEqual(imported, 2, "the batch-advisory treatment never blocks a row from committing")

        let importedTxs = try ModelContext(container).fetch(FetchDescriptor<Transaction>()).filter { $0.source == .imported }
        XCTAssertEqual(importedTxs.count, 2)
        let matched = try XCTUnwrap(importedTxs.first { $0.descriptionText == "OMV Benzina" })
        let fresh = try XCTUnwrap(importedTxs.first { $0.descriptionText == "Something new" })
        XCTAssertEqual(matched.duplicateOfID, voiceTx.id, "the colliding row is flagged")
        XCTAssertNil(fresh.duplicateOfID, "a genuinely new row is never flagged")
    }

    // MARK: - P9 bank feed × DedupOrigin.bank (fix cycle: was missing, silently
    // collapsed into .autoLoggedIntent — the SINGLE most likely real-world
    // duplicate pair, Apple Pay auto-capture vs. the bank feed for the same card
    // payment, was never flagged)

    func testBankCollidesWithAutoLogIntent() throws {
        let ctx = try makeContext()
        let now = Date()
        let intentTx = try AutoLogWriter.log(
            AutoLogPayload(amountText: "45", currencyCode: "RON", merchant: "Mega Image", date: now, origin: .intent),
            in: ctx
        )
        let bankTx = saveBank(amount: 45, description: "Mega Image", counterparty: "Mega Image", date: now, bankKey: "bk-intent", in: ctx)
        XCTAssertEqual(bankTx.duplicateOfID, intentTx.id,
                       "an Apple Pay auto-capture and the bank-feed row for the SAME card payment must collide — the single most likely real-world duplicate pair")
    }

    func testBankCollidesWithAutoLogShare() throws {
        let ctx = try makeContext()
        let now = Date()
        let shareTx = AutoLogWriter.logShared(
            amount: 45, currency: .ron, descriptionText: "Mega Image", merchant: "Mega Image",
            direction: .expense, rawText: "notificare Mega Image 45 RON", in: ctx
        )
        let bankTx = saveBank(amount: 45, description: "Mega Image", counterparty: "Mega Image", date: now, bankKey: "bk-share", in: ctx)
        XCTAssertEqual(bankTx.duplicateOfID, shareTx.id, "a shared bank-notification capture and the bank-feed row for the same payment must collide")
    }

    func testBankCollidesWithVoice() throws {
        let ctx = try makeContext()
        let now = Date()
        let voiceTx = saveVoice(amount: 61, description: "OMV Benzina", date: now, in: ctx)
        let bankTx = saveBank(amount: 61, description: "OMV Benzina", counterparty: "OMV", date: now, bankKey: "bk-voice", in: ctx)
        XCTAssertEqual(bankTx.duplicateOfID, voiceTx.id, "a voice log and the bank-feed row for the same payment must collide")
    }

    func testBankCollidesWithManual() throws {
        let ctx = try makeContext()
        let now = Date()
        let manualTx = saveManual(amount: 15, description: "Taxi", date: now, in: ctx)
        let bankTx = saveBank(amount: 15, description: "Taxi", counterparty: "Taxi", date: now, bankKey: "bk-manual", in: ctx)
        XCTAssertEqual(bankTx.duplicateOfID, manualTx.id, "a manual entry and the bank-feed row for the same payment must collide")
    }

    func testBankCollidesWithImport() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let now = Date()
        let bankTx = saveBank(amount: 61, description: "OMV Benzina", counterparty: "OMV", date: now, bankKey: "bk-import", in: ctx)
        let importedTx = try await commitImportRow(amount: 61, description: "OMV Benzina", date: now, in: container)
        XCTAssertEqual(importedTx.duplicateOfID, bankTx.id, "an imported row matching an existing bank-feed row must be flagged")
    }

    /// Bank×bank stays same-origin and is NEVER P8-flagged — P9's own bank-native
    /// key (embedded in `rawTranscript`, checked before insert even happens) is
    /// the ONLY thing guarding a re-pull from double-inserting; that mechanism is
    /// untouched by this fix (this test only proves P8's origin comparison, not
    /// the bank-key guard itself, which lives in `BankSyncService`/its own tests).
    func testBankBankNotFlagged() throws {
        let ctx = try makeContext()
        let now = Date()
        saveBank(amount: 61, description: "OMV Benzina", counterparty: "OMV", date: now, bankKey: "bk-a", in: ctx)
        let second = saveBank(amount: 61, description: "OMV Benzina", counterparty: "OMV", date: now, bankKey: "bk-b", in: ctx)
        XCTAssertNil(second.duplicateOfID, "bank+bank (same origin) is never P8-flagged, even with an identical shape and a different bank key")
    }

    /// Exclusion rules (P4 adjustments, P3 loan slices) are unchanged for bank
    /// rows: a bank-feed row is never matched against either, even with a
    /// perfectly matching shape.
    func testBankRowNeverCollidesWithLoanSliceOrReconciliationAdjustment() throws {
        let ctx = try makeContext()
        let now = Date()
        let loanTx = Transaction(amount: 200, currency: .ron, context: .work, descriptionText: "Loan interest",
                                 date: now, source: .manual, direction: .expense, loanID: UUID())
        ctx.insert(loanTx)
        let adjustmentTx = Transaction(amount: 88, currency: .ron, context: .personal,
                                       customCategoryID: ReconciliationCategories.adjustmentCategoryID,
                                       descriptionText: "Balance adjustment", date: now, source: .manual, direction: .income)
        ctx.insert(adjustmentTx)
        try ctx.save()

        let bankLoanShaped = saveBank(amount: 200, description: "Loan interest", counterparty: "Loan interest", date: now, bankKey: "bk-loan", in: ctx)
        XCTAssertNil(bankLoanShaped.duplicateOfID, "a bank row is never matched against a loan slice, even with a matching shape")

        let bankAdjustmentShaped = saveBank(amount: 88, description: "Balance adjustment", counterparty: "Balance adjustment",
                                            date: now, direction: .income, bankKey: "bk-adj", in: ctx)
        XCTAssertNil(bankAdjustmentShaped.duplicateOfID, "a bank row is never matched against a reconciliation adjustment, even with a matching shape")
    }
}
