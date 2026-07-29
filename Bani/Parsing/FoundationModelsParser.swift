import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence parser (iOS 26 Foundation Models framework).
///
/// Availability-gated on `SystemLanguageModel.default.availability`: only proceeds
/// when `.available`. Every other path — unavailability, `FoundationModels` not
/// importable on the building SDK, any thrown error, or a mapping failure where the
/// model extracted nothing usable — **silently falls back** to `fallback.parse(text)`.
/// This type never throws and never crashes; `parse` always returns a value.
struct FoundationModelsParser: TransactionParsing {
    private let fallback: any TransactionParsing

    init(fallback: any TransactionParsing) {
        self.fallback = fallback
    }

    func parse(_ text: String) async -> ParsedTransaction {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            return await fallback.parse(text)
        }

        do {
            let session = LanguageModelSession(
                instructions: """
                You extract structured transaction data from a short spoken or typed \
                note describing a single purchase or expense. The note may be in \
                Romanian or English, or mix the two. Preserve Romanian diacritics \
                (ă, â, î, ș, ț) exactly as written — never strip or transliterate them. \
                Common Romanian finance phrasing includes amounts followed by a \
                currency word, e.g. "50 de lei benzină", "douăzeci de euro taxi", \
                "12,50 lei cafea". Extract:
                - amount: the numeric amount spent, if one is stated. Never guess or \
                invent an amount — if no amount is mentioned anywhere in the text, \
                leave it unset.
                - currencyCode: "RON" if the text mentions "lei", "de lei", or "ron"; \
                "EUR" if it mentions "euro", "eur", or "€"; otherwise leave it empty.
                - descriptionText: what was purchased, i.e. the remaining text with the \
                amount and currency words removed, diacritics preserved verbatim.
                - merchant: the merchant or vendor name, only if one is clearly stated.
                """
            )

            let response = try await session.respond(
                to: text,
                generating: ExtractedTransaction.self
            )

            guard let parsed = Self.map(response.content) else {
                return await fallback.parse(text)
            }
            return parsed
        } catch {
            return await fallback.parse(text)
        }
        #else
        return await fallback.parse(text)
        #endif
    }

    #if canImport(FoundationModels)
    /// Maps the model's structured output into `ParsedTransaction`.
    /// Returns `nil` (→ caller falls back) only when the model extracted nothing
    /// usable at all: no amount, no description, no merchant.
    private static func map(_ extracted: ExtractedTransaction) -> ParsedTransaction? {
        let normalizedCode = extracted.currencyCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let currency: Currency
        switch normalizedCode {
        case "EUR":
            currency = .eur
        default:
            // "RON", empty, or anything unrecognized → default RON (never invent
            // an unsupported currency).
            currency = .ron
        }

        let description = extracted.descriptionText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedMerchant = extracted.merchant?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let merchant = (trimmedMerchant?.isEmpty ?? true) ? nil : trimmedMerchant

        guard extracted.amount != nil || !description.isEmpty || merchant != nil else {
            return nil
        }

        return ParsedTransaction(
            amount: extracted.amount,
            currency: currency,
            descriptionText: description,
            merchant: merchant
        )
    }
    #endif
}

#if canImport(FoundationModels)
/// Structured extraction target for `LanguageModelSession.respond(to:generating:)`.
/// `Decimal` (and `Decimal?`) conforms to `Generable` directly — money stays `Decimal`.
@Generable
private struct ExtractedTransaction {
    @Guide(description: "The numeric amount spent. Left unset if no amount was stated — never invent one.")
    var amount: Decimal?

    @Guide(description: "Currency mentioned for the amount, or empty if none was said.", .anyOf(["RON", "EUR", ""]))
    var currencyCode: String

    @Guide(description: "The purchase description with amount/currency words removed; diacritics preserved.")
    var descriptionText: String

    @Guide(description: "Merchant or vendor name, only if clearly stated in the text.")
    var merchant: String?
}
#endif
