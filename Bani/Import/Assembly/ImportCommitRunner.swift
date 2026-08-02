import Foundation
import SwiftData

/// One draft ready to commit, with its resolved context + optional attachment.
struct CommitItem: Sendable {
    var draft: DraftTransaction
    var context: TransactionContext
    var attachment: PendingAttachment?
}

/// Commits the confirmed report as ONE `ImportBatch` (F: "Confirm commits ALL
/// files as ONE ImportBatch; undo covers everything, attachments included").
/// Runs off the main actor with its own `ModelContext`, resolves each draft's
/// category (seeded custom / preset / by-description), writes direction +
/// counterparty (A1/A2/B2) and saves any document attachment (E2). Chunked saves
/// keep memory flat; cancellation rolls back this run's rows + attachments.
@ModelActor
actor ImportCommitRunner {

    static let chunkSize = 200

    func commit(
        items: [CommitItem],
        fileName: String,
        contextChoice: String,
        notes: String,
        skippedCount: Int,
        onProgress: @Sendable (ImportProgress) async -> Void
    ) async -> ImportRunOutcome {
        let batchID = UUID()
        let total = items.count
        let resolution = PresetSeeding.ensureCustoms(in: modelContext)   // token → custom id
        let snapshots = ruleSnapshots()

        var savedAttachments: [UUID] = []
        var inserted = 0
        for (offset, item) in items.enumerated() {
            if Task.isCancelled {
                rollback(batchID: batchID, attachmentIDs: savedAttachments)
                return .cancelled
            }

            var attachmentID: UUID?
            if let attachment = item.attachment {
                let id = UUID()
                if AttachmentStore.save(id: id, originalData: attachment.originalData, originalFileName: attachment.originalFileName, extractedText: attachment.extractedText, summary: attachment.summary) {
                    attachmentID = id
                    savedAttachments.append(id)
                }
            }

            let tx = Transaction(
                amount: item.draft.amount,
                currency: item.draft.currency,
                context: item.context,
                descriptionText: item.draft.descriptionText,
                date: item.draft.date,
                rawTranscript: nil,
                source: .imported,
                direction: item.draft.direction,
                counterparty: item.draft.counterparty,
                attachmentID: attachmentID,
                importBatchID: batchID
            )
            tx.categoryRef = resolve(item.draft.category, resolution: resolution, snapshots: snapshots, description: item.draft.descriptionText)
            modelContext.insert(tx)
            inserted += 1

            if (offset + 1) % Self.chunkSize == 0 {
                try? modelContext.save()
                await onProgress(ImportProgress(processed: offset + 1, total: total))
            }
        }

        if Task.isCancelled {
            rollback(batchID: batchID, attachmentIDs: savedAttachments)
            return .cancelled
        }

        let batch = ImportBatch(id: batchID, fileName: fileName, rowCount: inserted, skippedCount: skippedCount, contextChoice: contextChoice, notes: notes)
        modelContext.insert(batch)
        try? modelContext.save()
        await onProgress(ImportProgress(processed: total, total: total))
        return .completed(batchID: batchID, imported: inserted)
    }

    // MARK: - Category resolution

    private func resolve(_ category: DraftCategory, resolution: [SeededCustomCategory: UUID], snapshots: [CategoryRuleSnapshot], description: String) -> CategoryRef? {
        switch category {
        case .seededCustom(let sc):
            if let id = resolution[sc] { return .custom(id) }
            return .preset(.other)
        case .preset(let p): return .preset(p)
        case .byDescription: return Categorizer.categoryRef(for: description, rules: snapshots)
        case .uncategorized: return nil
        }
    }

    private func ruleSnapshots() -> [CategoryRuleSnapshot] {
        let rules = (try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? []
        return rules.map { CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, customCategoryID: $0.customCategoryID, origin: $0.origin, hitCount: $0.hitCount) }
    }

    private func rollback(batchID: UUID, attachmentIDs: [UUID]) {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        for tx in all where tx.importBatchID == batchID { modelContext.delete(tx) }
        try? modelContext.save()
        AttachmentStore.delete(attachmentIDs: attachmentIDs.map { $0 as UUID? })
    }
}
