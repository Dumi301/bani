import Foundation
import SwiftData

/// The `@MainActor` SwiftData side of import batches (C5/C6/D): list past batches,
/// undo a batch (delete its transactions + the record), and compute the existing
/// import fingerprints for the batch-level dedup guard. Mirrors the other stores —
/// pure query/mutation bridging, no view state. Optional-UUID equality is filtered
/// in memory (matching the store style for columns `#Predicate` can't translate).
@MainActor
enum ImportBatchStore {

    // MARK: - Reading

    static func allBatches(in context: ModelContext) -> [ImportBatchSnapshot] {
        let descriptor = FetchDescriptor<ImportBatch>(sortBy: [SortDescriptor(\ImportBatch.importedAt, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).map(\.snapshot)
    }

    static func batchCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<ImportBatch>())) ?? 0
    }

    /// How many transactions currently belong to a batch (the undo confirmation count).
    static func transactionCount(batchID: UUID, in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.filter { $0.importBatchID == batchID }.count
    }

    /// Fingerprints of every previously-imported transaction, for the dedup guard.
    static func existingImportFingerprints(in context: ModelContext) -> Set<String> {
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        var out = Set<String>()
        for tx in all where tx.source == .imported {
            out.insert(ImportFingerprint.fingerprint(date: tx.date, amount: tx.amount, description: tx.descriptionText))
        }
        return out
    }

    // MARK: - Writing

    /// Undo an import (C5/C6): delete every transaction with `batchID` and the
    /// batch record. Returns the number of transactions removed. Custom categories
    /// created during the import are deliberately kept (the user chose to create
    /// them; they can be removed from Categories management).
    @discardableResult
    static func undo(batchID: UUID, in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        var removed = 0
        for tx in all where tx.importBatchID == batchID {
            context.delete(tx)
            removed += 1
        }
        let batches = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
        for batch in batches where batch.id == batchID { context.delete(batch) }
        try? context.save()
        return removed
    }
}
