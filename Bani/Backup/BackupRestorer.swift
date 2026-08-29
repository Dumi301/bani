import Foundation
import SwiftData

/// Typed restore failures, surfaced in the Settings UI (`BackupView`).
enum RestoreError: Error, Equatable, Sendable {
    /// `restore()` refuses a non-empty store; the counts are what's currently
    /// there, for the UI's "erase and restore instead?" prompt.
    case storeNotEmpty(counts: [BackupEntity: Int])
    /// The archive's `formatVersion` is newer than this build understands.
    case unsupportedVersion(found: Int, supported: Int)
    /// Missing/unreadable entry, bad JSON, or an unparseable `Decimal` — anything
    /// that means the archive cannot be trusted. Carries a short diagnostic, not
    /// shown verbatim to the user (the UI maps this to `backup.error.corrupt`).
    case corruptArchive(String)
}

/// Restores a `.bani-backup` archive (`BackupArchiver`'s output) into the live
/// store. `@ModelActor`, mirroring `ImportRunner`.
///
/// All-or-nothing (P1 design notes item 5): every row is decoded AND converted
/// (`Decimal` parse, DTO → `@Model`) into plain, unattached model instances BEFORE
/// the first `modelContext.insert` — a corrupt or truncated archive throws with
/// the store completely untouched, never a partial write.
@ModelActor
actor BackupRestorer {

    // MARK: - Public API

    /// v1 policy: refuses to restore into a non-empty store. Callers should catch
    /// `RestoreError.storeNotEmpty` and offer `eraseAndRestore` instead.
    @discardableResult
    func restore(archive: Data) throws -> BackupManifest {
        let decoded = try decode(archive)
        let existing = try currentCounts()
        guard !existing.values.contains(where: { $0 > 0 }) else {
            throw RestoreError.storeNotEmpty(counts: existing)
        }
        return try applyRestore(decoded, erasing: false)
    }

    /// Replaces the entire store with the archive's contents, ATOMICALLY: the
    /// erase (row deletes) and the restore (row inserts) commit in a single
    /// `modelContext.save()`, and attachment blobs are swapped only after that
    /// save durably succeeds. The archive is decoded and fully converted BEFORE
    /// anything is deleted, so a corrupt archive never destroys real data — and
    /// (H2 fix) a save failure at the commit rolls the deletes back, so a FAILED
    /// erase-and-restore leaves the previous data + blobs fully intact.
    @discardableResult
    func eraseAndRestore(archive: Data) throws -> BackupManifest {
        let decoded = try decode(archive)
        return try applyRestore(decoded, erasing: true)
    }

    /// Manifest-only peek (UI confirm-dialog preview / row-count display) — reads
    /// `manifest.json` alone, touches no entity rows and no store.
    func peekManifest(archive: Data) throws -> BackupManifest {
        try decodeManifest(archive)
    }

    /// Current row counts across all 13 entities — the store-empty gate for
    /// `restore()`, and available to the UI to preview an erase.
    func currentCounts() throws -> [BackupEntity: Int] {
        [
            .transaction: try modelContext.fetchCount(FetchDescriptor<Transaction>()),
            .categoryRule: try modelContext.fetchCount(FetchDescriptor<CategoryRule>()),
            .decisionRecord: try modelContext.fetchCount(FetchDescriptor<DecisionRecord>()),
            .contextRule: try modelContext.fetchCount(FetchDescriptor<ContextRule>()),
            .correctionMemory: try modelContext.fetchCount(FetchDescriptor<CorrectionMemory>()),
            .customCategory: try modelContext.fetchCount(FetchDescriptor<CustomCategory>()),
            .importBatch: try modelContext.fetchCount(FetchDescriptor<ImportBatch>()),
            .project: try modelContext.fetchCount(FetchDescriptor<Project>()),
            .person: try modelContext.fetchCount(FetchDescriptor<Person>()),
            .scheduledItem: try modelContext.fetchCount(FetchDescriptor<ScheduledItem>()),
            .balanceAnchor: try modelContext.fetchCount(FetchDescriptor<BalanceAnchor>()),
            .loan: try modelContext.fetchCount(FetchDescriptor<Loan>()),
            .bankLink: try modelContext.fetchCount(FetchDescriptor<BankLink>()),
        ]
    }

    // MARK: - Decode (pure — no `modelContext` access, nothing written yet)

    private struct DecodedBackup {
        var manifest: BackupManifest
        var transactions: [Transaction]
        var categoryRules: [CategoryRule]
        var decisionRecords: [DecisionRecord]
        var contextRules: [ContextRule]
        var correctionMemories: [CorrectionMemory]
        var customCategories: [CustomCategory]
        var importBatches: [ImportBatch]
        var projects: [Project]
        var people: [Person]
        var scheduledItems: [ScheduledItem]
        var balanceAnchors: [BalanceAnchor]
        var loans: [Loan]
        var bankLinks: [BankLink]
        var attachments: [(id: UUID, files: [(name: String, data: Data)])]
    }

    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Must mirror `BackupArchiver`'s custom strategy exactly. NOT `.iso8601`
        // (truncates fractional seconds) and NOT `.secondsSince1970` (round-trips
        // through the 1970 epoch even though `Date` natively stores its interval
        // since the 2001 reference date — that extra offset add/subtract loses a
        // ULP on recent dates, so a restored `Date` fails exact `Equatable`
        // comparison despite printing identically to the original; see
        // `BackupArchiver`'s encoder comment). Decoding the native
        // `timeIntervalSinceReferenceDate` directly is bit-exact, zero-conversion.
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        return decoder
    }

    private func decodeManifest(_ archive: Data) throws -> BackupManifest {
        guard let data = MinimalZip.extract(entrySuffix: "manifest.json", from: archive) else {
            throw RestoreError.corruptArchive("missing manifest.json")
        }
        let manifest = try decodeOrThrow(BackupManifest.self, from: data)
        guard manifest.formatVersion <= BackupManifest.currentFormatVersion else {
            throw RestoreError.unsupportedVersion(found: manifest.formatVersion, supported: BackupManifest.currentFormatVersion)
        }
        return manifest
    }

    private func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try jsonDecoder().decode(type, from: data) }
        catch { throw RestoreError.corruptArchive("\(type): \(error)") }
    }

    private func rows<T: Decodable>(_ entity: BackupEntity, as type: T.Type, from archive: Data) throws -> [T] {
        guard let data = MinimalZip.extract(entrySuffix: entity.fileName, from: archive) else {
            throw RestoreError.corruptArchive("missing \(entity.fileName)")
        }
        return try decodeOrThrow([T].self, from: data)
    }

    private func decode(_ archive: Data) throws -> DecodedBackup {
        let manifest = try decodeManifest(archive)

        let transactions = try rows(.transaction, as: TransactionDTO.self, from: archive).map { try $0.makeModel() }
        let categoryRules = try rows(.categoryRule, as: CategoryRuleDTO.self, from: archive).map { $0.makeModel() }
        let decisionRecords = try rows(.decisionRecord, as: DecisionRecordDTO.self, from: archive).map { $0.makeModel() }
        let contextRules = try rows(.contextRule, as: ContextRuleDTO.self, from: archive).map { $0.makeModel() }
        let correctionMemories = try rows(.correctionMemory, as: CorrectionMemoryDTO.self, from: archive).map { $0.makeModel() }
        let customCategories = try rows(.customCategory, as: CustomCategoryDTO.self, from: archive).map { $0.makeModel() }
        let importBatches = try rows(.importBatch, as: ImportBatchDTO.self, from: archive).map { $0.makeModel() }
        let projects = try rows(.project, as: ProjectDTO.self, from: archive).map { $0.makeModel() }
        let people = try rows(.person, as: PersonDTO.self, from: archive).map { $0.makeModel() }
        let scheduledItems = try rows(.scheduledItem, as: ScheduledItemDTO.self, from: archive).map { try $0.makeModel() }
        let balanceAnchors = try rows(.balanceAnchor, as: BalanceAnchorDTO.self, from: archive).map { try $0.makeModel() }
        let loans = try rows(.loan, as: LoanDTO.self, from: archive).map { try $0.makeModel() }
        let bankLinks = try rows(.bankLink, as: BankLinkDTO.self, from: archive).map { $0.makeModel() }

        var attachments: [(id: UUID, files: [(name: String, data: Data)])] = []
        if let attachmentsData = MinimalZip.extract(entrySuffix: "attachments.json", from: archive) {
            let entries = try decodeOrThrow([BackupAttachmentEntry].self, from: attachmentsData)
            for entry in entries {
                var files: [(String, Data)] = []
                for name in entry.files {
                    let path = "attachments/\(entry.attachmentID.uuidString)/\(name)"
                    guard let data = MinimalZip.extract(entrySuffix: path, from: archive) else {
                        throw RestoreError.corruptArchive("missing attachment file \(path)")
                    }
                    files.append((name, data))
                }
                attachments.append((entry.attachmentID, files))
            }
        }

        return DecodedBackup(
            manifest: manifest, transactions: transactions, categoryRules: categoryRules,
            decisionRecords: decisionRecords, contextRules: contextRules, correctionMemories: correctionMemories,
            customCategories: customCategories, importBatches: importBatches, projects: projects, people: people,
            scheduledItems: scheduledItems, balanceAnchors: balanceAnchors, loans: loans, bankLinks: bankLinks,
            attachments: attachments
        )
    }

    // MARK: - Commit seam (test-only save-failure injection)

    /// Test seam: when non-nil, this closure REPLACES the single
    /// `modelContext.save()` at the restore commit boundary, letting a test
    /// inject a throwing "disk full / store locked / constraint" save and prove
    /// the rollback leaves the prior data + blobs fully intact. `nil` in
    /// production — `commit()` runs the real `save()`, so the shipped path is
    /// byte-for-byte unchanged.
    private var commitFailureHook: (@Sendable () throws -> Void)? = nil

    /// Installs the commit-failure seam (test-only). Actor-isolated, so a caller
    /// `await`s it before invoking a restore; production never calls it.
    func injectCommitFailure(_ hook: @escaping @Sendable () throws -> Void) {
        commitFailureHook = hook
    }

    /// The ONE save boundary for every restore. Production runs
    /// `modelContext.save()`; a test may substitute a throwing hook to simulate a
    /// failed commit at exactly this point.
    private func commit() throws {
        if let commitFailureHook { try commitFailureHook() }
        else { try modelContext.save() }
    }

    // MARK: - Write (only reached once EVERY row above decoded cleanly)

    /// Applies a decoded backup as a SINGLE atomic transaction, then swaps blobs.
    ///
    /// The invariant this method exists to guarantee (H2): **a failed restore
    /// leaves the previous data fully intact.** Concretely:
    ///  1. Incoming attachment blobs are staged into a private temp dir OUTSIDE
    ///     `AttachmentStore.root`, so a same-filename collision with a live blob
    ///     can never clobber it before the commit succeeds. Staging runs before
    ///     any erase, so a staging failure throws with the store untouched.
    ///  2. When `erasing`, the row deletes and the restored inserts are batched
    ///     into ONE `commit()` — no intermediate save. Any throw before/at that
    ///     save triggers `rollback()`, returning the store to its exact
    ///     pre-restore state (deletes undone, inserts discarded). No `@Model` in
    ///     the 13-entity schema declares `@Attribute(.unique)`, so re-inserting a
    ///     row whose `id` matches a just-deleted row's `id` carries no
    ///     unique-constraint risk inside the single transaction — delete+insert
    ///     coexist safely up to the commit point (design req. 4).
    ///  3. Only AFTER the commit durably succeeds are the old blobs deleted and
    ///     the staged blobs moved into place. On failure the staged temp is
    ///     discarded (via `defer`) and the old blobs are never touched.
    @discardableResult
    private func applyRestore(_ decoded: DecodedBackup, erasing: Bool) throws -> BackupManifest {
        // (1) Stage incoming blobs off to the side — never under AttachmentStore.root.
        let staging = try stageIncomingAttachments(decoded.attachments)
        defer { try? FileManager.default.removeItem(at: staging.root) }

        // Snapshot the blobs we'll retire — BEFORE deleting the rows that name them.
        let oldAttachmentIDs: [UUID?] = erasing ? currentAttachmentIDs() : []

        // (2) Single transaction: (optional) deletes + restored inserts, one save.
        do {
            if erasing { deleteAllRows() }   // deletes only — NO save, NO blob IO
            insertRows(decoded)              // inserts only — NO save
            try commit()                     // the ONE save boundary
        } catch {
            modelContext.rollback()          // undoes the deletes AND the inserts
            throw error                      // staging discarded via defer; old blobs untouched
        }

        // (3) Past the durable commit — now, and only now, mutate the blob store:
        //     retire the old blobs, then move the staged incoming blobs into place.
        //     Best-effort (matches `AttachmentStore.save`'s no-throw philosophy):
        //     a file move failure here cannot invalidate the already-saved rows.
        if erasing { AttachmentStore.delete(attachmentIDs: oldAttachmentIDs) }
        installStagedAttachments(staging)

        return decoded.manifest
    }

    /// Inserts every decoded row. No `save()` — the caller's `commit()` is the
    /// single save boundary. `insert` itself cannot throw.
    private func insertRows(_ decoded: DecodedBackup) {
        decoded.transactions.forEach { modelContext.insert($0) }
        decoded.categoryRules.forEach { modelContext.insert($0) }
        decoded.decisionRecords.forEach { modelContext.insert($0) }
        decoded.contextRules.forEach { modelContext.insert($0) }
        decoded.correctionMemories.forEach { modelContext.insert($0) }
        decoded.customCategories.forEach { modelContext.insert($0) }
        decoded.importBatches.forEach { modelContext.insert($0) }
        decoded.projects.forEach { modelContext.insert($0) }
        decoded.people.forEach { modelContext.insert($0) }
        decoded.scheduledItems.forEach { modelContext.insert($0) }
        decoded.balanceAnchors.forEach { modelContext.insert($0) }
        decoded.loans.forEach { modelContext.insert($0) }
        decoded.bankLinks.forEach { modelContext.insert($0) }
    }

    /// The attachment IDs currently referenced by stored transactions — captured
    /// before an erase so their on-disk blobs can be deleted AFTER the commit.
    private func currentAttachmentIDs() -> [UUID?] {
        ((try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.attachmentID)
    }

    /// Deletes every row of all 13 entities (fetch-then-delete loop,
    /// `ImportBatchStore.undo` style). Deletes ONLY — no `save()` (the caller's
    /// `commit()` is the single boundary) and no blob IO (blobs are retired only
    /// after the commit succeeds, in `applyRestore`).
    private func deleteAllRows() {
        for row in (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<DecisionRecord>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<ContextRule>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<CorrectionMemory>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<CustomCategory>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<ImportBatch>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<Project>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<Person>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<ScheduledItem>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<BalanceAnchor>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<Loan>())) ?? [] { modelContext.delete(row) }
        for row in (try? modelContext.fetch(FetchDescriptor<BankLink>())) ?? [] { modelContext.delete(row) }
    }

    // MARK: - Attachment blob staging (ordered around the save)

    /// A batch of incoming attachment blobs written to a private temp directory,
    /// ready to move into `AttachmentStore.root` once the store commit succeeds.
    private struct StagedAttachments {
        let root: URL
        let dirs: [(id: UUID, dir: URL)]
    }

    /// Writes every incoming attachment blob into a fresh temp directory OUTSIDE
    /// `AttachmentStore.root`. Runs BEFORE the erase/commit, so a failure here
    /// throws with the live store and every live blob completely untouched — no
    /// same-filename collision can reach an existing blob at this stage.
    private func stageIncomingAttachments(
        _ attachments: [(id: UUID, files: [(name: String, data: Data)])]
    ) throws -> StagedAttachments {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bani-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var dirs: [(id: UUID, dir: URL)] = []
        for (id, files) in attachments {
            let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in files {
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
            dirs.append((id, dir))
        }
        return StagedAttachments(root: root, dirs: dirs)
    }

    /// Moves the staged blobs into `AttachmentStore.root`, replacing any folder
    /// already at each destination (the archive is authoritative for its IDs).
    /// Best-effort by design (post-commit): a move failure here cannot invalidate
    /// the already-committed rows, matching `AttachmentStore.save`'s no-throw
    /// philosophy.
    private func installStagedAttachments(_ staging: StagedAttachments) {
        guard !staging.dirs.isEmpty else { return }
        try? FileManager.default.createDirectory(at: AttachmentStore.root, withIntermediateDirectories: true)
        for (id, stagedDir) in staging.dirs {
            let dest = AttachmentStore.root.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: stagedDir, to: dest)
        }
    }
}
