import Foundation
import SwiftData

/// Full-fidelity export of every entity in `BaniModelContainer.schema` (13, v2)
/// into a single `.bani-backup` file: a plain, hand-inspectable ZIP — one JSON
/// array per entity + a manifest + copied attachment blobs — built with the
/// proven store-only `StoreZipWriter` (`Bani/Reports/StoreZipWriter.swift`, P7).
/// No compression, no new dependency; reused as-is (P1 design notes / brief).
///
/// `@ModelActor`, mirroring `ImportRunner`: runs off the main actor with its own
/// `ModelContext`, read-only here — an export never mutates the store.
@ModelActor
actor BackupArchiver {

    /// Builds the complete `.bani-backup` archive bytes.
    ///
    /// Each entity fetch is TOLERANT (`try?` + empty-array fallback), not
    /// `try`: the real app container (`BaniModelContainer.shared`) always
    /// registers all 13 entities, so this never changes behavior in production.
    /// It exists so `BackupArchiver` also works against a container that
    /// registers only a SUBSET of the schema — e.g. the exact 7-entity
    /// container `DirectionNullMigrationTests` proves safe for reopening a
    /// legacy on-disk store (`BackupTestFixtures.legacyMigrationCurrentContainer`,
    /// used by `testLegacyNilDirectionRowBacksUpAsExpense`), where fetching an
    /// entity type the container never registered (`Project`, `Person`, …)
    /// would otherwise throw before ANY row could be archived. An entity absent
    /// from the container's schema simply counts 0 in the manifest.
    func makeArchive(appBuild: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0") throws -> Data {
        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let categoryRules = (try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? []
        let decisionRecords = (try? modelContext.fetch(FetchDescriptor<DecisionRecord>())) ?? []
        let contextRules = (try? modelContext.fetch(FetchDescriptor<ContextRule>())) ?? []
        let correctionMemories = (try? modelContext.fetch(FetchDescriptor<CorrectionMemory>())) ?? []
        let customCategories = (try? modelContext.fetch(FetchDescriptor<CustomCategory>())) ?? []
        let importBatches = (try? modelContext.fetch(FetchDescriptor<ImportBatch>())) ?? []
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        let scheduledItems = (try? modelContext.fetch(FetchDescriptor<ScheduledItem>())) ?? []
        let balanceAnchors = (try? modelContext.fetch(FetchDescriptor<BalanceAnchor>())) ?? []
        let loans = (try? modelContext.fetch(FetchDescriptor<Loan>())) ?? []
        let bankLinks = (try? modelContext.fetch(FetchDescriptor<BankLink>())) ?? []

        let encoder = JSONEncoder()
        // NOT `.iso8601`: `JSONEncoder`'s built-in ISO 8601 strategy formats
        // without fractional seconds by default, silently truncating every `Date`
        // to whole-second precision — a real round-trip bug for full-fidelity
        // backup (every `createdAt`/`updatedAt`/timestamp would drift by up to
        // ~1s after restore). `.secondsSince1970` encodes the same `Double`
        // `Date` already stores internally, so it round-trips exactly.
        encoder.dateEncodingStrategy = .secondsSince1970

        var entries: [StoreZipWriter.Entry] = []
        func add<T: Encodable>(_ fileName: String, _ value: T) throws {
            entries.append(StoreZipWriter.Entry(path: fileName, data: try encoder.encode(value)))
        }

        try add(BackupEntity.transaction.fileName, transactions.map(TransactionDTO.init))
        try add(BackupEntity.categoryRule.fileName, categoryRules.map(CategoryRuleDTO.init))
        try add(BackupEntity.decisionRecord.fileName, decisionRecords.map(DecisionRecordDTO.init))
        try add(BackupEntity.contextRule.fileName, contextRules.map(ContextRuleDTO.init))
        try add(BackupEntity.correctionMemory.fileName, correctionMemories.map(CorrectionMemoryDTO.init))
        try add(BackupEntity.customCategory.fileName, customCategories.map(CustomCategoryDTO.init))
        try add(BackupEntity.importBatch.fileName, importBatches.map(ImportBatchDTO.init))
        try add(BackupEntity.project.fileName, projects.map(ProjectDTO.init))
        try add(BackupEntity.person.fileName, people.map(PersonDTO.init))
        try add(BackupEntity.scheduledItem.fileName, scheduledItems.map(ScheduledItemDTO.init))
        try add(BackupEntity.balanceAnchor.fileName, balanceAnchors.map(BalanceAnchorDTO.init))
        try add(BackupEntity.loan.fileName, loans.map(LoanDTO.init))
        try add(BackupEntity.bankLink.fileName, bankLinks.map(BankLinkDTO.init))

        // Attachments (E2): every distinct, non-nil `attachmentID` referenced by a
        // Transaction — the only entity that carries one. Copies whatever files
        // actually exist under `AttachmentStore.root/<id>/` verbatim, and records
        // their exact names in `attachments.json` so `BackupRestorer` never has to
        // enumerate the zip's central directory (design notes item 4 — the PUBLIC
        // `AttachmentStore.root` + `<attachmentID>/` layout; `folder(for:)` itself
        // is private by design, so we rebuild the path by convention here).
        var attachmentEntries: [BackupAttachmentEntry] = []
        let attachmentIDs = Set(transactions.compactMap(\.attachmentID))
        for id in attachmentIDs {
            let dir = AttachmentStore.root.appendingPathComponent(id.uuidString, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            var names: [String] = []
            for fileURL in files {
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                let name = fileURL.lastPathComponent
                entries.append(StoreZipWriter.Entry(path: "attachments/\(id.uuidString)/\(name)", data: data))
                names.append(name)
            }
            if !names.isEmpty { attachmentEntries.append(BackupAttachmentEntry(attachmentID: id, files: names)) }
        }
        try add("attachments.json", attachmentEntries)

        let manifest = BackupManifest(
            appBuild: appBuild,
            counts: [
                .transaction: transactions.count, .categoryRule: categoryRules.count,
                .decisionRecord: decisionRecords.count, .contextRule: contextRules.count,
                .correctionMemory: correctionMemories.count, .customCategory: customCategories.count,
                .importBatch: importBatches.count, .project: projects.count,
                .person: people.count, .scheduledItem: scheduledItems.count,
                .balanceAnchor: balanceAnchors.count, .loan: loans.count, .bankLink: bankLinks.count,
            ]
        )
        try add("manifest.json", manifest)

        return StoreZipWriter.archive(entries)
    }
}
