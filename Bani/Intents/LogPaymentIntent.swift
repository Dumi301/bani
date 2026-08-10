import AppIntents
import Foundation

/// Apple Pay auto-logging (Part A). The client sets up an iOS Shortcuts personal
/// automation — trigger: a Wallet card transaction → run this intent, "Run
/// Immediately" — so every Apple Pay tap logs itself into Bani with merchant +
/// amount, zero taps.
///
/// `openAppWhenRun == false`: it runs in the background with no UI. iOS launches
/// the app process to perform it; the write goes to `BaniModelContainer.shared`,
/// the SAME on-disk store the foreground app uses. The amount is bound as a STRING
/// (the Shortcuts Transaction trigger passes its amount as text), so money never
/// touches `Double` on the way in — it is parsed by the hardened `AmountLexer`. A
/// garbage amount throws a user-visible error; it never saves a zero-amount row.
struct LogPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Payment in Bani"
    static let description = IntentDescription(
        "Logs a card payment into Bani with its merchant and amount — no taps. Point a Wallet-transaction Shortcuts automation at this and run it immediately."
    )
    /// Background — never foregrounds the app for an auto-logged payment.
    static let openAppWhenRun = false

    @Parameter(title: "Amount")
    var amountText: String

    @Parameter(title: "Currency Code")
    var currencyCode: String?

    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Card")
    var cardName: String?

    @Parameter(title: "Date")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amountText) at \(\.$merchant)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let payload = AutoLogPayload(
            amountText: amountText,
            currencyCode: currencyCode,
            merchant: merchant,
            cardName: cardName,
            date: date ?? Date(),
            origin: .intent
        )
        // Throws AutoLogError on an unparseable/implausible amount — surfaced to the
        // Shortcuts run as a user-visible error, never a zero-amount save.
        let transaction = try AutoLogWriter.log(payload, in: BaniModelContainer.shared.mainContext)

        let amountDisplay = "\(NSDecimalNumber(decimal: transaction.amount).stringValue) \(transaction.currency.displayCode)"
        let name = AutoLogWriter.cleanedMerchant(merchant) ?? String(localized: "autolog.description.fallback")
        // Idiomatic IntentDialog interpolation (Shortcuts-facing confirmation).
        return .result(dialog: "Logged \(amountDisplay) at \(name)")
    }
}
