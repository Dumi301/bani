import Foundation
import SwiftData

/// One Excel/CSV history-import run (v1.1). A NEW, separate SwiftData entity —
/// the frozen `Transaction` model is untouched except for the two documented
/// additive fields (`source == .imported`, `importBatchID`). Adding this entity
/// to the container is a lightweight, additive migration; existing rows are
/// untouched.
///
/// Every imported `Transaction` carries `importBatchID == self.id`, so the whole
/// batch can be undone (deleted) atomically, and the Settings → Import history
/// screen can list past imports with a per-batch undo.
@Model
final class ImportBatch {
    var id: UUID
    /// The picked file's display name (e.g. "cheltuieli-2023.xlsx").
    var fileName: String
    var importedAt: Date
    /// Rows actually written as transactions.
    var rowCount: Int
    /// Rows skipped (unparseable date/amount/description) — surfaced in the summary.
    var skippedCount: Int
    /// The context applied to the whole batch, stored as `TransactionContext.rawValue`
    /// when a fixed context was chosen, or the sentinel `"column"` when context came
    /// from a mapped column. Kept as a raw string so the model has no enum-migration
    /// surface of its own.
    var contextChoice: String
    /// Free-form provenance note (sheet name, negatives policy, date format used).
    var notes: String

    init(
        id: UUID = UUID(),
        fileName: String,
        importedAt: Date = .now,
        rowCount: Int,
        skippedCount: Int,
        contextChoice: String,
        notes: String = ""
    ) {
        self.id = id
        self.fileName = fileName
        self.importedAt = importedAt
        self.rowCount = rowCount
        self.skippedCount = skippedCount
        self.contextChoice = contextChoice
        self.notes = notes
    }
}

/// A value-type snapshot of one `ImportBatch`, so views/pure logic can render the
/// history list without a live `ModelContext` (mirrors `CustomCategorySnapshot`).
struct ImportBatchSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let importedAt: Date
    let rowCount: Int
    let skippedCount: Int
    let contextChoice: String
    let notes: String
}

extension ImportBatch {
    var snapshot: ImportBatchSnapshot {
        ImportBatchSnapshot(
            id: id, fileName: fileName, importedAt: importedAt,
            rowCount: rowCount, skippedCount: skippedCount,
            contextChoice: contextChoice, notes: notes
        )
    }
}
