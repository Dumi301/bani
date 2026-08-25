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
        return try insertAndSave(decoded)
    }

    /// Deletes every row of every entity (+ their attachment blobs), THEN
    /// restores. The archive is decoded and fully converted BEFORE the erase, so
    /// a corrupt archive never destroys real data.
    @discardableResult
    func eraseAndRestore(archive: Data) throws -> BackupManifest {
        let decoded = try decode(archive)
        eraseAllRows()
        return try insertAndSave(decoded)
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
        // Must mirror `BackupArchiver`'s `.secondsSince1970` exactly (NOT
        // `.iso8601` — see the comment there on the fractional-seconds
        // truncation bug that strategy has).
        decoder.dateDecodingStrategy = .secondsSince1970
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

    // MARK: - Write (only reached once EVERY row above decoded cleanly)

    private func insertAndSave(_ decoded: DecodedBackup) throws -> BackupManifest {
        do {
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
            try modelContext.save()
        } catch {
            // Defensive — `insert` itself can't fail, but a `save()` failure
            // should never leave a half-applied restore in the context.
            modelContext.rollback()
            throw error
        }

        // Attachment blobs are a separate (non-SwiftData) persistence layer,
        // written only after the store save succeeds — best-effort, matching
        // `AttachmentStore.save`'s own no-throw philosophy: a failed file write
        // never invalidates the (already-saved) transaction rows.
        for (id, files) in decoded.attachments {
            let dir = AttachmentStore.root.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in files {
                try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
        }

        return decoded.manifest
    }

    /// Deletes every row of all 13 entities + their attachment blobs
    /// (fetch-then-delete loop, `ImportBatchStore.undo` style).
    private func eraseAllRows() {
        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        var attachmentIDs: [UUID?] = []
        for tx in transactions {
            attachmentIDs.append(tx.attachmentID)
            modelContext.delete(tx)
        }
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
        try? modelContext.save()
        AttachmentStore.delete(attachmentIDs: attachmentIDs)
    }
}
