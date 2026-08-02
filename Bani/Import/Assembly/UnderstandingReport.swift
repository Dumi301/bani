import Foundation

/// A file's headline outcome, rendered as the ✓ / ⚠ / ✗ chip (F).
enum FileStatus: String, Sendable, Equatable {
    case ok         // ✓ imported cleanly
    case warning    // ⚠ imported, but something needs a look (skips, low confidence, questions)
    case failed     // ✗ nothing importable (unreadable / no transactions / skipped family E)

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
    var tagColorName: String {
        switch self {
        case .ok: "BaniAccent"
        case .warning: "BaniTagWork"
        case .failed: "BaniTagWork"
        }
    }
}

/// One recognized worksheet's summary chip (multi-sheet workbooks show one per
/// sheet — bug #5 single-pass).
struct SheetSummary: Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    /// Display role: "A"…"D" family, "generic", or "skipped".
    var roleLabelKey: String
    var importedCount: Int
    var skippedCount: Int
    /// Localization keys for the plain-language skip/why notes.
    var noteKeys: [String]
}

/// A pending document attachment (E2) — the original bytes + cached extraction,
/// saved to `AttachmentStore` only on Confirm.
struct PendingAttachment: Sendable, Equatable {
    var originalData: Data
    var originalFileName: String
    var extractedText: String
    var summary: String
}

/// One picked file's report entry (F). Mutable fields (`appliedContext`, the
/// document `drafts`) are edited inline in the report before Confirm.
struct FileReport: Identifiable, Sendable, Equatable {
    var id = UUID()
    var fileName: String
    var status: FileStatus
    var isDocument: Bool
    var usedOCR: Bool
    /// Set when the file couldn't be read at all (✗) — a plain reason, not a raw error.
    var unreadableReasonKey: String?
    var sheets: [SheetSummary]
    var drafts: [DraftTransaction]
    var skippedCount: Int
    /// File-level plain-language notes (OCR language fallback, ambiguous date…).
    var noteKeys: [String]
    /// H1 — generic tabular + documents ask a Personal/Work question; families don't.
    var needsContextChoice: Bool
    var appliedContext: TransactionContext
    /// Whether the demoted wizard's "fix mapping" hatch applies (generic tabular, D5).
    var canFixMapping: Bool
    /// Document editing state (E).
    var extraction: ExtractedTransaction?
    var attachment: PendingAttachment?

    var importedCount: Int { drafts.count }
}

/// The user's grouped answers to the report's cross-file questions (F, D4).
struct ReportDecisions: Sendable, Equatable {
    /// D4 — default skip rows that look already-imported (cross-batch).
    var skipDuplicates: Bool = true
    /// Negatives policy, shown ONLY when negatives exist.
    var negativesPolicy: NegativesPolicy = .absolute
}

/// The whole understanding report shown after processing (F). Pure value type so
/// the report UI is a projection and the pipeline is unit-testable end-to-end.
struct UnderstandingReport: Sendable {
    var files: [FileReport]
    /// D4 — draft ids whose fingerprint already exists among prior imports.
    var duplicateDraftIDs: Set<UUID>
    var negativesFound: Bool
    var decisions: ReportDecisions
    var importDate: Date

    var allFiles: [FileReport] { files }
    var totalImported: Int { files.reduce(0) { $0 + $1.drafts.count } }
    var totalSkipped: Int { files.reduce(0) { $0 + $1.skippedCount } }
    var duplicateCount: Int { duplicateDraftIDs.count }
    /// The drafts that will actually commit under the current decisions.
    var committableDrafts: [(fileIndex: Int, draft: DraftTransaction, context: TransactionContext, attachment: PendingAttachment?)] {
        var out: [(fileIndex: Int, draft: DraftTransaction, context: TransactionContext, attachment: PendingAttachment?)] = []
        for (i, file) in files.enumerated() {
            for draft in file.drafts {
                if decisions.skipDuplicates && duplicateDraftIDs.contains(draft.id) { continue }
                out.append((fileIndex: i, draft: draft, context: file.appliedContext, attachment: file.attachment))
            }
        }
        return out
    }
}
