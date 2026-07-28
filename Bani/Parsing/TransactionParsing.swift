import Foundation

/// The structured result of parsing a spoken/typed utterance into transaction fields.
/// `amount` is `nil` when no amount could be found — the parser NEVER invents a number.
struct ParsedTransaction: Equatable, Sendable {
    var amount: Decimal?
    var currency: Currency
    var descriptionText: String
    var merchant: String?

    init(
        amount: Decimal?,
        currency: Currency = .ron,
        descriptionText: String,
        merchant: String? = nil
    ) {
        self.amount = amount
        self.currency = currency
        self.descriptionText = descriptionText
        self.merchant = merchant
    }
}

/// Contract for turning transcript/text into a `ParsedTransaction`.
///
/// - `RuleBasedParser` is the default everywhere (deterministic, offline).
/// - `FoundationModelsParser` is availability-gated and silently falls back to
///   `RuleBasedParser` on unavailability or any error.
///
/// `parse` is `async` to accommodate the Foundation Models implementation; the
/// rule-based implementation simply returns synchronously inside the async call.
/// Implementations must not throw — failures resolve to a best-effort result or
/// a fallback (see `FoundationModelsParser`).
protocol TransactionParsing: Sendable {
    func parse(_ text: String) async -> ParsedTransaction
}
