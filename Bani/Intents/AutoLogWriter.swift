import Foundation
import SwiftData

/// The verbatim payload an auto-logging capture hands to the write path — an Apple
/// Pay `LogPaymentIntent` (`.intent`) or a share-sheet capture (`.share`). Money
/// arrives as TEXT so it never passes through `Double` on the way in; `cardName`
/// and `merchant` are preserved verbatim into `rawTranscript` for future search.
struct AutoLogPayload: Sendable, Equatable {
    var amountText: String
    var currencyCode: String?
    var merchant: String?
    var cardName: String?
    var date: Date
    var origin: Origin

    /// Distinguishes the two capture routes that share the single `.autoLogged`
    /// seam — surfaced only as the `rawTranscript` prefix, never a second source case.
    enum Origin: String, Sendable, Equatable {
        case intent   // Apple Pay Shortcuts automation
        case share    // share-sheet capture (Part B)
        var prefix: String { self == .intent ? "[intent]" : "[share]" }
    }

    init(amountText: String, currencyCode: String? = nil, merchant: String? = nil,
         cardName: String? = nil, date: Date = .now, origin: Origin = .intent) {
        self.amountText = amountText
        self.currencyCode = currencyCode
        self.merchant = merchant
        self.cardName = cardName
        self.date = date
        self.origin = origin
    }
}

/// The one thing the auto-log write path can fail on: an amount that is not a
/// single plausible number. Surfaced to the user (Shortcuts dialog / test-row
/// alert) — the write NEVER falls back to a zero-amount save.
enum AutoLogError: Error, LocalizedError, Equatable {
    case unparseableAmount(String)

    var errorDescription: String? {
        switch self {
        case .unparseableAmount(let raw):
            return String(localized: "autolog.error.amount \(raw)")
        }
    }
}

/// The shared, UI-free write routine for an auto-logged payment. Called by
/// `LogPaymentIntent.perform()`, the Settings "test intent" row, and
/// `LogPaymentIntentTests` — one implementation, so the intent and the tests
/// exercise identical decision logic. `@MainActor` because it reads the learned
/// category/context rules and writes the SwiftData `mainContext`.
@MainActor
enum AutoLogWriter {

    /// RON default; a recognised ISO code (`EUR`) maps; anything else falls back to
    /// RON rather than inventing a currency.
    static func currency(for code: String?) -> Currency {
        guard let code, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return .ron }
        return Currency(rawValue: code.trimmingCharacters(in: .whitespaces).uppercased()) ?? .ron
    }

    /// The plausible magnitude of the amount text (via the hardened `AmountLexer`,
    /// so float-dust + the plausibility cap are inherited), or a thrown error. A
    /// zero / blank / multi-number / implausible cell throws — never a silent save.
    static func resolveAmount(_ text: String) throws -> Decimal {
        switch AmountLexer.classifyCell(text) {
        case .value(let amount):
            return amount.magnitude
        case .implausible, .none:
            throw AutoLogError.unparseableAmount(text)
        }
    }

    /// v1.2a — the last-used project to assign to an auto-logged entry: the
    /// persisted project (`lastUsedProjectID`) when the resolved context is Work AND
    /// it still exists (non-archived), else `nil`. Personal is never project-tagged.
    /// Clamps against the store so a deleted/archived last-used never leaves a dead id.
    static func lastUsedProject(for resolvedContext: TransactionContext, in modelContext: ModelContext) -> UUID? {
        let raw = UserDefaults.standard.string(forKey: "lastUsedProjectID") ?? ""
        guard let id = ProjectAssignment.smartDefault(context: resolvedContext, lastUsedRaw: raw) else { return nil }
        let existing = (try? modelContext.fetch(FetchDescriptor<Project>()))?.first { $0.id == id && !$0.archived }
        return existing?.id
    }

    /// The cleaned merchant, trimmed of whitespace; `nil`/blank stays `nil`.
    static func cleanedMerchant(_ merchant: String?) -> String? {
        guard let merchant else { return nil }
        let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The description shown on the row/card: the cleaned merchant, else a generic
    /// localized "Card payment" (never blank).
    static func description(for payload: AutoLogPayload) -> String {
        cleanedMerchant(payload.merchant) ?? String(localized: "autolog.description.fallback")
    }

    /// The verbatim payload, origin-tagged, preserved as `rawTranscript` for future
    /// semantic search (merchant + card + amount + currency, exactly as received).
    static func rawTranscript(for payload: AutoLogPayload, amount: Decimal, currency: Currency) -> String {
        var parts: [String] = [payload.origin.prefix]
        if let merchant = cleanedMerchant(payload.merchant) { parts.append(merchant) }
        if let card = cleanedMerchant(payload.cardName) { parts.append("card \(card)") }
        let amountString = NSDecimalNumber(decimal: amount).stringValue
        parts.append("\(amountString) \(currency.displayCode)")
        return parts.joined(separator: " · ")
    }

    /// Write a full first-class `Transaction` for an auto-logged payment: direction
    /// `.expense`, learned category + context pre-selection (learns from later
    /// corrections exactly like voice), `source == .autoLogged`, verbatim payload in
    /// `rawTranscript`. Returns the inserted transaction. Throws only on an
    /// unparseable amount (before anything is inserted).
    @discardableResult
    static func log(_ payload: AutoLogPayload, in context: ModelContext) throws -> Transaction {
        let amount = try resolveAmount(payload.amountText)
        let currency = currency(for: payload.currencyCode)
        let merchant = cleanedMerchant(payload.merchant)
        let description = description(for: payload)

        // Category guess (learned rules win; falls back to .other) + learned context
        // pre-selection, else Personal — the same seams the voice card uses.
        let categoryRef = CategoryRuleStore.guessRef(description: description, merchant: merchant, in: context)
        let selectedContext = ContextRuleStore.preselectedContext(description: description, merchant: merchant, in: context) ?? .personal
        // v1.2a: a Work auto-log carries the last-used project (Personal never does);
        // the review chip can correct it.
        let projectID = lastUsedProject(for: selectedContext, in: context)

        let transaction = Transaction(
            amount: amount,
            currency: currency,
            context: selectedContext,
            descriptionText: description,
            merchant: merchant,
            date: payload.date,
            rawTranscript: rawTranscript(for: payload, amount: amount, currency: currency),
            source: .autoLogged,
            direction: .expense,
            projectID: projectID
        )
        transaction.categoryRef = categoryRef
        context.insert(transaction)
        try? context.save()
        // P8 — never silently double-count: flag (never drop) a cross-source
        // possible duplicate for the review surface.
        DedupService.flagIfDuplicate(transaction, in: context)
        return transaction
    }

    /// Part B — write a share-sheet capture as an `.autoLogged` transaction after
    /// the user confirmed it on the pre-filled card. Same seam as the intent
    /// (`.autoLogged`), differentiated only by the `[share]` `rawTranscript` prefix
    /// preserving the verbatim captured text. Direction comes from the parse
    /// (income/expense); the amount is already a confirmed `Decimal` from the card.
    @discardableResult
    static func logShared(
        amount: Decimal,
        currency: Currency,
        descriptionText: String,
        merchant: String?,
        direction: TransactionDirection,
        rawText: String,
        in context: ModelContext
    ) -> Transaction {
        let cleanMerchant = cleanedMerchant(merchant)
        let typed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription = typed.isEmpty ? (cleanMerchant ?? String(localized: "autolog.description.fallback")) : typed
        let categoryRef = CategoryRuleStore.guessRef(description: finalDescription, merchant: cleanMerchant, in: context)
        let selectedContext = ContextRuleStore.preselectedContext(description: finalDescription, merchant: cleanMerchant, in: context) ?? .personal
        let cleanRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        let transaction = Transaction(
            amount: amount,
            currency: currency,
            context: selectedContext,
            descriptionText: finalDescription,
            merchant: cleanMerchant,
            date: .now,
            rawTranscript: "\(AutoLogPayload.Origin.share.prefix) \(cleanRaw)",
            source: .autoLogged,
            direction: direction
        )
        transaction.categoryRef = categoryRef
        context.insert(transaction)
        try? context.save()
        // P8 — never silently double-count: flag (never drop) a cross-source
        // possible duplicate for the review surface.
        DedupService.flagIfDuplicate(transaction, in: context)
        return transaction
    }
}
