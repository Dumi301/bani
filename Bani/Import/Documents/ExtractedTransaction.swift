import Foundation

/// The kind of document an extractor recognized (drives the report chip + the
/// direction guess).
enum DocType: String, Sendable, Equatable, CaseIterable {
    case contract
    case invoice
    case receipt
    case unknown

    var label: String {
        switch self {
        case .contract: String(localized: "doc.type.contract")
        case .invoice: String(localized: "doc.type.invoice")
        case .receipt: String(localized: "doc.type.receipt")
        case .unknown: String(localized: "doc.type.unknown")
        }
    }
}

/// The structured result of understanding ONE document (E1). Every field is
/// optional/low-confidence-flaggable because a document is inherently fuzzier than
/// a spreadsheet cell — the report surfaces low-confidence fields for the user to
/// confirm, and NOTHING is saved before Confirm.
struct ExtractedTransaction: Sendable, Equatable {
    var amount: Decimal?
    var currency: Currency
    /// `nil` → the extractor found no date; the pipeline falls back to the import
    /// date and sets `dateWasFallback` (flagged in the report — E1).
    var date: Date?
    var dateWasFallback: Bool
    var counterparty: String?
    var descriptionText: String
    var direction: TransactionDirection
    var docType: DocType
    /// 2–3 sentence plain-language summary, in the document's own language.
    var summary: String

    // Per-field confidence (0…1), for the low-confidence flagging in the report.
    var amountConfidence: Double
    var dateConfidence: Double
    var counterpartyConfidence: Double

    /// Whether the extraction is strong enough to present as a ready draft (vs an
    /// "I couldn't read this" ✗). A found amount is the minimum bar.
    var hasUsableAmount: Bool { amount != nil && amountConfidence > 0 }

    /// Overall confidence — the min of the fields that were found (a chain is as
    /// weak as its weakest link).
    var overallConfidence: Double {
        var scores = [amountConfidence]
        if date != nil, !dateWasFallback { scores.append(dateConfidence) }
        if counterparty != nil { scores.append(counterpartyConfidence) }
        return scores.min() ?? 0
    }

    static func empty(currency: Currency = .ron) -> ExtractedTransaction {
        ExtractedTransaction(
            amount: nil, currency: currency, date: nil, dateWasFallback: false,
            counterparty: nil, descriptionText: "", direction: .expense,
            docType: .unknown, summary: "", amountConfidence: 0,
            dateConfidence: 0, counterpartyConfidence: 0
        )
    }
}

/// The understanding seam (E1). Implementations now: `HeuristicExtractor` (regex
/// cascade) and `FoundationModelsExtractor` (@Generable, availability-gated with a
/// silent heuristic fallback). Run 2's local-LLM engine AND the future in-app
/// assistant consume this SAME seam — documented in build-notes.md so the Run-2
/// worker wires the engine here rather than re-plumbing the pipeline.
protocol DocumentUnderstanding: Sendable {
    /// Whether this extractor can run right now (FoundationModels availability).
    var isAvailable: Bool { get }
    /// Understand one document's text. Never throws — an unreadable document yields
    /// a low/zero-confidence result the report shows as ✗, never a crash.
    func understand(text: String, fileName: String, importDate: Date) async -> ExtractedTransaction
}
