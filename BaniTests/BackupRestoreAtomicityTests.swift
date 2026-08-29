import XCTest
import SwiftData
@testable import Bani

/// H2 regression coverage: `BackupRestorer.eraseAndRestore` must be ATOMIC — the
/// erase (row deletes + old blob removal) and the restore (row inserts + new blob
/// install) either both take effect or neither does. The pre-fix code committed
/// the erase (its own `save()` + blob delete) before the inserts, so a failing
/// final `save()` left an empty store with the attachments already gone — the
/// exact catastrophe the backup feature exists to prevent.
///
/// The failure is injected through `BackupRestorer.injectCommitFailure`, a
/// test-only seam that swaps a throwing closure in for the single
/// `modelContext.save()` at the restore commit boundary (production path
/// unchanged: the hook is `nil`, the real `save()` runs). All three tests share
/// the fixtures declared in `BackupRoundTripTests.swift` (same test target).
@MainActor
final class BackupRestoreAtomicityTests: XCTestCase {

    private enum InjectedSaveFailure: Error { case diskFull }

    // MARK: - Failed restore leaves every entity row + blobs intact

    /// A save failure at the commit point must roll the erase back: every one of
    /// the 13 entities keeps its rows, the archive's replacement rows never land,
    /// and the pre-existing attachment blob is byte-for-byte untouched.
    func testFailedEraseAndRestoreLeavesEveryEntityRowIntact() async throws {
        // Target: one row of every entity in the 13-entity schema + a real
        // on-disk attachment blob (carried by the "huge" transaction).
        let targetContainer = try BackupTestFixtures.makeInMemorySeededContainer()
        let before = try entityCounts(ModelContext(targetContainer))
        XCTAssertGreaterThan(before.values.reduce(0, +), 0, "sanity: the target starts non-empty")

        let seededAttachmentID = try XCTUnwrap(
            try ModelContext(targetContainer)
                .fetch(FetchDescriptor<Transaction>())
                .first { $0.descriptionText == BackupTestFixtures.hugeDescription }?
                .attachmentID
        )
        let seededBlobURL = try XCTUnwrap(AttachmentStore.originalURL(id: seededAttachmentID))
        XCTAssertEqual(try Data(contentsOf: seededBlobURL), BackupTestFixtures.attachmentBytes,
                       "sanity: the seeded attachment blob is present before the restore")

        // Source archive: a single, clearly-distinct transaction (no attachment),
        // so we can prove none of it landed.
        let replacementMarker = "REPLACEMENT-\(UUID().uuidString)"
        let sourceContainer = try BaniModelContainer.make(inMemory: true)
        let sourceContext = ModelContext(sourceContainer)
        sourceContext.insert(Transaction(amount: 7, currency: .ron, context: .personal,
                                          descriptionText: replacementMarker, source: .manual))
        try sourceContext.save()
        let archive = try await BackupArchiver(modelContainer: sourceContainer).makeArchive()

        let restorer = BackupRestorer(modelContainer: targetContainer)
        await restorer.injectCommitFailure { throw InjectedSaveFailure.diskFull }
        do {
            _ = try await restorer.eraseAndRestore(archive: archive)
            XCTFail("expected the injected save failure to propagate")
        } catch InjectedSaveFailure.diskFull {
            // expected — the commit threw exactly where a disk-full save would.
        }

        // Every entity's rows survived — the erase was rolled back wholesale.
        let after = try entityCounts(ModelContext(targetContainer))
        XCTAssertEqual(after, before, "a failed restore must leave every entity row intact")

        // The archive's replacement row never landed.
        let survivors = try ModelContext(targetContainer).fetch(FetchDescriptor<Transaction>())
        XCTAssertFalse(survivors.contains { $0.descriptionText == replacementMarker },
                       "the archive's replacement row must not have been committed")

        // The pre-existing attachment blob is byte-for-byte intact (never deleted,
        // never overwritten — the erase's blob removal runs only after a commit).
        let afterBlobURL = try XCTUnwrap(AttachmentStore.originalURL(id: seededAttachmentID),
                                         "the pre-existing attachment blob must still exist")
        XCTAssertEqual(try Data(contentsOf: afterBlobURL), BackupTestFixtures.attachmentBytes,
                       "the pre-existing attachment blob must be unchanged after a failed restore")

        AttachmentStore.delete(id: seededAttachmentID)
    }

    // MARK: - Failed restore never clobbers a colliding blob before the commit

    /// The archive carries an attachment whose ID collides with a live blob but
    /// whose bytes differ. Because incoming blobs are staged to a temp dir and
    /// moved into place only AFTER a successful commit, a failing commit must
    /// leave the OLD blob bytes on disk — the staged new bytes are discarded, and
    /// the target's row is restored by the rollback.
    func testFailedEraseAndRestoreDoesNotClobberCollidingBlobBeforeCommit() async throws {
        let attachmentID = UUID()
        let newBytes = Data("NEW-BLOB-FROM-ARCHIVE".utf8)
        let oldBytes = Data("OLD-BLOB-ON-DEVICE".utf8)

        // 1. Write the NEW blob, build a source archive that references it (the
        //    archive captures the NEW bytes into the zip)…
        XCTAssertTrue(AttachmentStore.save(id: attachmentID, originalData: newBytes,
                                           originalFileName: "doc.pdf", extractedText: "new-extract",
                                           summary: "new-sum"))
        let sourceContainer = try BaniModelContainer.make(inMemory: true)
        let sourceContext = ModelContext(sourceContainer)
        sourceContext.insert(Transaction(amount: 5, currency: .ron, context: .personal,
                                          descriptionText: "source", source: .manual,
                                          attachmentID: attachmentID))
        try sourceContext.save()
        let archive = try await BackupArchiver(modelContainer: sourceContainer).makeArchive()

        // 2. …then overwrite the SAME on-disk folder with the OLD bytes: this is
        //    now the device's live blob, colliding by ID (and filename) with the
        //    archive's copy.
        XCTAssertTrue(AttachmentStore.save(id: attachmentID, originalData: oldBytes,
                                           originalFileName: "doc.pdf", extractedText: "old-extract",
                                           summary: "old-sum"))

        // 3. Target store: a row that references the live (old) blob.
        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let targetContext = ModelContext(targetContainer)
        let targetRowID = UUID()
        targetContext.insert(Transaction(id: targetRowID, amount: 1, currency: .ron, context: .personal,
                                          descriptionText: "target-row", source: .manual,
                                          attachmentID: attachmentID))
        try targetContext.save()

        let restorer = BackupRestorer(modelContainer: targetContainer)
        await restorer.injectCommitFailure { throw InjectedSaveFailure.diskFull }
        do {
            _ = try await restorer.eraseAndRestore(archive: archive)
            XCTFail("expected the injected save failure to propagate")
        } catch InjectedSaveFailure.diskFull {
            // expected
        }

        // The live blob still holds the OLD bytes — staging never touched it.
        let blobURL = try XCTUnwrap(AttachmentStore.originalURL(id: attachmentID),
                                    "the colliding blob must still exist after a failed restore")
        XCTAssertEqual(try Data(contentsOf: blobURL), oldBytes,
                       "the staged archive blob must NOT have clobbered the live blob before the commit")
        XCTAssertEqual(AttachmentStore.extractedText(id: attachmentID), "old-extract",
                       "every file of the colliding blob must be the pre-restore copy")

        // The target row was restored by the rollback (erase undone).
        let rows = try ModelContext(targetContainer).fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, 1, "the erased row must be rolled back")
        XCTAssertEqual(rows.first?.id, targetRowID)

        AttachmentStore.delete(id: attachmentID)
    }

    // MARK: - Successful restore retires old blobs and installs the new ones

    /// The happy path the failure tests mirror: a successful `eraseAndRestore`
    /// removes the pre-existing store's attachment blobs and installs the
    /// archive's, and the restored rows replace the stale ones.
    func testEraseAndRestoreSucceedsRetiresOldBlobsInstallsNew() async throws {
        let oldID = UUID()
        let newID = UUID()
        let oldBytes = Data("STALE-BLOB".utf8)
        let newBytes = Data("RESTORED-BLOB".utf8)

        // Build the archive around the NEW blob, then remove it from disk so the
        // pre-restore device state is ONLY the stale blob — proving the install
        // (not a leftover) is what puts the new blob in place.
        XCTAssertTrue(AttachmentStore.save(id: newID, originalData: newBytes, originalFileName: "new.pdf",
                                           extractedText: "new-extract", summary: "new-sum"))
        let sourceContainer = try BaniModelContainer.make(inMemory: true)
        let sourceContext = ModelContext(sourceContainer)
        sourceContext.insert(Transaction(amount: 9, currency: .ron, context: .personal,
                                          descriptionText: "restored-row", source: .manual,
                                          attachmentID: newID))
        try sourceContext.save()
        let archive = try await BackupArchiver(modelContainer: sourceContainer).makeArchive()
        AttachmentStore.delete(id: newID)

        // The stale on-device blob + the row that references it.
        XCTAssertTrue(AttachmentStore.save(id: oldID, originalData: oldBytes, originalFileName: "old.pdf",
                                           extractedText: "old-extract", summary: "old-sum"))
        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let targetContext = ModelContext(targetContainer)
        let staleRowID = UUID()
        targetContext.insert(Transaction(id: staleRowID, amount: 1, currency: .ron, context: .personal,
                                          descriptionText: "stale-row", source: .manual,
                                          attachmentID: oldID))
        try targetContext.save()

        let restorer = BackupRestorer(modelContainer: targetContainer)
        let manifest = try await restorer.eraseAndRestore(archive: archive)
        XCTAssertEqual(manifest[.transaction], 1)

        // Old blob retired, new blob installed with the archive's exact bytes.
        XCTAssertNil(AttachmentStore.originalURL(id: oldID), "the old blob must be gone after a successful restore")
        let newBlobURL = try XCTUnwrap(AttachmentStore.originalURL(id: newID), "the new blob must be installed")
        XCTAssertEqual(try Data(contentsOf: newBlobURL), newBytes)
        XCTAssertEqual(AttachmentStore.extractedText(id: newID), "new-extract")

        // The stale row is gone; the restored row (referencing the new blob) is present.
        let rows = try ModelContext(targetContainer).fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows.contains { $0.id == staleRowID }, "the stale row must be erased")
        XCTAssertEqual(rows.first?.attachmentID, newID)

        AttachmentStore.delete(id: newID)
    }

    // MARK: - Helper

    /// Row counts for all 13 entities keyed by `BackupEntity.rawValue`, so a
    /// before/after comparison covers every entity in one assertion.
    private func entityCounts(_ ctx: ModelContext) throws -> [String: Int] {
        [
            BackupEntity.transaction.rawValue: try ctx.fetchCount(FetchDescriptor<Transaction>()),
            BackupEntity.categoryRule.rawValue: try ctx.fetchCount(FetchDescriptor<CategoryRule>()),
            BackupEntity.decisionRecord.rawValue: try ctx.fetchCount(FetchDescriptor<DecisionRecord>()),
            BackupEntity.contextRule.rawValue: try ctx.fetchCount(FetchDescriptor<ContextRule>()),
            BackupEntity.correctionMemory.rawValue: try ctx.fetchCount(FetchDescriptor<CorrectionMemory>()),
            BackupEntity.customCategory.rawValue: try ctx.fetchCount(FetchDescriptor<CustomCategory>()),
            BackupEntity.importBatch.rawValue: try ctx.fetchCount(FetchDescriptor<ImportBatch>()),
            BackupEntity.project.rawValue: try ctx.fetchCount(FetchDescriptor<Project>()),
            BackupEntity.person.rawValue: try ctx.fetchCount(FetchDescriptor<Person>()),
            BackupEntity.scheduledItem.rawValue: try ctx.fetchCount(FetchDescriptor<ScheduledItem>()),
            BackupEntity.balanceAnchor.rawValue: try ctx.fetchCount(FetchDescriptor<BalanceAnchor>()),
            BackupEntity.loan.rawValue: try ctx.fetchCount(FetchDescriptor<Loan>()),
            BackupEntity.bankLink.rawValue: try ctx.fetchCount(FetchDescriptor<BankLink>()),
        ]
    }
}
