import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence document extractor (iOS 26 Foundation Models),
/// the second `DocumentUnderstanding` implementation (E1). Availability-gated on
/// `SystemLanguageModel.default.availability`; every other path — unavailable,
/// `FoundationModels` not importable on the building SDK, any thrown error, or an
/// extraction with no usable amount — **silently falls back** to the
/// `HeuristicExtractor`. Never throws, never crashes.
///
/// RUN-2 NOTE: this is the seam Run 2's local-LLM engine and the future in-app
/// assistant plug into — swap the model/prompt here, the pipeline is unchanged
/// (see build-notes.md).
struct FoundationModelsExtractor: DocumentUnderstanding {
    private let fallback: HeuristicExtractor

    init(fallback: HeuristicExtractor = HeuristicExtractor()) {
        self.fallback = fallback
    }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    func understand(text: String, fileName: String, importDate: Date) async -> ExtractedTransaction {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            return fallback.extractSync(text: text, fileName: fileName, importDate: importDate)
        }
        do {
            let session = LanguageModelSession(
                instructions: """
                You extract ONE structured transaction from a financial document \
                (a contract, invoice, or receipt). The document may be Romanian or \
                English. Preserve Romanian diacritics (ă, â, î, ș, ț) verbatim. \
                Romanian writes thousands with a dot and decimals with a comma, so \
                "1.200,50" means 1200.50. Extract the primary amount, its currency \
                ("RON" for lei, "EUR" for euro), the transaction date if stated, the \
                counterparty (the other party: tenant/landlord/provider/client), a \
                short description, the document type, and a 2–3 sentence summary in \
                the document's OWN language. Never invent an amount or a date.
                """
            )
            let response = try await session.respond(to: String(text.prefix(6000)), generating: ExtractedDocument.self)
            guard let mapped = Self.map(response.content, importDate: importDate) else {
                return fallback.extractSync(text: text, fileName: fileName, importDate: importDate)
            }
            return mapped
        } catch {
            return fallback.extractSync(text: text, fileName: fileName, importDate: importDate)
        }
        #else
        return fallback.extractSync(text: text, fileName: fileName, importDate: importDate)
        #endif
    }

    #if canImport(FoundationModels)
    private static func map(_ doc: ExtractedDocument, importDate: Date) -> ExtractedTransaction? {
        let currency: Currency = doc.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EUR" ? .eur : .ron
        let party = doc.counterparty?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanParty = (party?.isEmpty ?? true) ? nil : party
        let date = doc.isoDate.flatMap { DocumentDates.firstDate(in: $0) }
        let docType = DocType(rawValue: doc.docType.lowercased()) ?? .unknown
        guard doc.amount != nil || !doc.descriptionText.isEmpty else { return nil }
        return ExtractedTransaction(
            amount: doc.amount, currency: currency, date: date ?? importDate,
            dateWasFallback: date == nil, counterparty: cleanParty,
            descriptionText: doc.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            direction: .expense, docType: docType, summary: doc.summary,
            amountConfidence: doc.amount == nil ? 0 : 0.9,
            dateConfidence: date == nil ? 0 : 0.85,
            counterpartyConfidence: cleanParty == nil ? 0 : 0.8
        )
    }
    #endif
}

#if canImport(FoundationModels)
/// Structured extraction target for the document seam. Named distinctly from the
/// module-level `ExtractedTransaction` (the seam value type) to avoid confusion.
@Generable
private struct ExtractedDocument {
    @Guide(description: "The primary amount stated in the document. Unset if none — never invent one.")
    var amount: Decimal?
    @Guide(description: "Currency of the amount.", .anyOf(["RON", "EUR", ""]))
    var currencyCode: String
    @Guide(description: "The transaction/contract date as yyyy-MM-dd, or empty if not stated.")
    var isoDate: String?
    @Guide(description: "The counterparty (tenant/landlord/provider/client), if named.")
    var counterparty: String?
    @Guide(description: "A short description of what the document is for.")
    var descriptionText: String
    @Guide(description: "Document type.", .anyOf(["contract", "invoice", "receipt", "unknown"]))
    var docType: String
    @Guide(description: "A 2–3 sentence plain-language summary in the document's own language.")
    var summary: String
}
#endif
