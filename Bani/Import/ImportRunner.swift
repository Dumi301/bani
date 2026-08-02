import Foundation
import SwiftData

/// The resolved decision for one distinct category-column value (C2). Built by the
/// wizard for EVERY distinct value: auto-matches become `.existing`, and the user
/// resolves the rest. `.create` is realized into a real `CustomCategory` on the
/// import actor (which owns a `ModelContext`).
enum ImportCategoryDecision: Equatable, Sendable {
    case existing(CategoryRef)
    case create(name: String, symbolName: String, colorIndex: Int)
    case uncategorized
}

/// Progress ticked once per saved chunk (C4).
struct ImportProgress: Equatable, Sendable {
    var processed: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(processed) / Double(total) : 0 }
}

/// The terminal outcome of an import run.
enum ImportRunOutcome: Equatable, Sendable {
    case completed(batchID: UUID, imported: Int)
    case cancelled
}

/// Executes an import off the main actor with its OWN `ModelContext` (C4).
/// Inserts in chunks, saving each so memory stays flat and progress advances;
/// honors cancellation by rolling back exactly this run's rows (and any custom
/// categories it created) via the batch id — an import is never left half-visible.
///
/// A background context: the app's `@Query`-bound main context sees the writes
/// through SwiftData's store propagation, and the wizard is a full-screen cover,
/// so the Finances list/charts effectively refresh once, on completion.
@ModelActor
actor ImportRunner {

    static let chunkSize = 200

    /// Run the import. `decisions` is keyed by the NORMALIZED category value.
    func run(
        rows: [ParsedImportRow],
        fileName: String,
        contextChoice: String,
        notes: String,
        skippedCount: Int,
        decisions: [String: ImportCategoryDecision],
        onProgress: @Sendable (ImportProgress) async -> Void
    ) async -> ImportRunOutcome {
        let batchID = UUID()
        let total = rows.count

        // Live rule snapshots for the by-description categorization path (no
        // learning is written — this is a read-only guess, scope guard E).
        let snapshots = ruleSnapshots()

        // Pre-create the custom categories the user asked for (find-or-create,
        // once per normalized name). Tracked so a cancel can remove them.
        var createdCategoryIDs: [UUID] = []
        var createdByKey: [String: UUID] = [:]
        for (key, decision) in decisions {
            if case let .create(name, symbol, colorIndex) = decision {
                let id = findOrCreateCustom(name: name, symbolName: symbol, colorIndex: colorIndex, tracking: &createdCategoryIDs)
                createdByKey[key] = id
            }
        }

        var inserted = 0
        for (offset, row) in rows.enumerated() {
            if Task.isCancelled {
                rollback(batchID: batchID, createdCategoryIDs: createdCategoryIDs)
                return .cancelled
            }

            let tx = Transaction(
                amount: row.amount,
                currency: row.currency,
                context: row.context,
                descriptionText: row.descriptionText,
                date: row.date,
                rawTranscript: nil,             // scope guard E — imported rows carry none
                source: .imported,
                direction: row.direction,       // A1 — expense/income/neutral from the family parser
                counterparty: row.counterparty, // A2/B2 — extracted party
                importBatchID: batchID
            )
            tx.categoryRef = resolveCategory(for: row, decisions: decisions, createdByKey: createdByKey, snapshots: snapshots)
            modelContext.insert(tx)
            inserted += 1

            if (offset + 1) % Self.chunkSize == 0 {
                try? modelContext.save()
                await onProgress(ImportProgress(processed: offset + 1, total: total))
            }
        }

        // Final cancellation check before committing the batch record.
        if Task.isCancelled {
            rollback(batchID: batchID, createdCategoryIDs: createdCategoryIDs)
            return .cancelled
        }

        let batch = ImportBatch(
            id: batchID, fileName: fileName,
            rowCount: inserted, skippedCount: skippedCount,
            contextChoice: contextChoice, notes: notes
        )
        modelContext.insert(batch)
        try? modelContext.save()
        await onProgress(ImportProgress(processed: total, total: total))
        return .completed(batchID: batchID, imported: inserted)
    }

    // MARK: - Category resolution

    private func resolveCategory(
        for row: ParsedImportRow,
        decisions: [String: ImportCategoryDecision],
        createdByKey: [String: UUID],
        snapshots: [CategoryRuleSnapshot]
    ) -> CategoryRef? {
        switch row.categorySource {
        case .byDescription:
            // Existing Categorizer guess (seeds + learned rules); .other fallback.
            return Categorizer.categoryRef(for: row.descriptionText, rules: snapshots)
        case .uncategorized:
            return nil
        case .columnValue(let value):
            let key = Categorizer.normalize(value)
            switch decisions[key] {
            case .existing(let ref): return ref
            case .create: return createdByKey[key].map { .custom($0) }
            case .uncategorized, .none: return nil
            }
        }
    }

    // MARK: - SwiftData helpers (on the actor's context)

    private func ruleSnapshots() -> [CategoryRuleSnapshot] {
        let rules = (try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? []
        return rules.map {
            CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, customCategoryID: $0.customCategoryID, origin: $0.origin, hitCount: $0.hitCount)
        }
    }

    private func findOrCreateCustom(name: String, symbolName: String, colorIndex: Int, tracking created: inout [UUID]) -> UUID {
        let target = Categorizer.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let existing = (try? modelContext.fetch(FetchDescriptor<CustomCategory>())) ?? []
        if let match = existing.first(where: { Categorizer.normalize($0.name) == target }) {
            return match.id
        }
        let category = CustomCategory(name: name.trimmingCharacters(in: .whitespacesAndNewlines), symbolName: symbolName, colorIndex: colorIndex)
        modelContext.insert(category)
        try? modelContext.save()
        created.append(category.id)
        return category.id
    }

    /// Delete every transaction written under `batchID` plus any custom categories
    /// this run created (never orphaning empty categories from an aborted run).
    private func rollback(batchID: UUID, createdCategoryIDs: [UUID]) {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        for tx in all where tx.importBatchID == batchID { modelContext.delete(tx) }
        if !createdCategoryIDs.isEmpty {
            let ids = Set(createdCategoryIDs)
            let customs = (try? modelContext.fetch(FetchDescriptor<CustomCategory>())) ?? []
            for c in customs where ids.contains(c.id) { modelContext.delete(c) }
        }
        try? modelContext.save()
    }
}
