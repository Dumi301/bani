import Foundation
import SwiftData

/// P9 — pulls booked bank transactions and lands them in the EXISTING auto-log
/// review flow. Runs off the main actor (`@ModelActor`, its own `ModelContext` over
/// the shared store — the `ImportCommitRunner` pattern) so a foreground/manual sync
/// never blocks the UI.
///
/// Pipeline per transaction: decode → map to a `BankDraft` (`Decimal` amount from
/// the signed STRING, direction from the sign, counterparty from creditor/debtor,
/// date from `bookingDate`) → annotate the category via P10's
/// `InterpretationService` (deterministic on CI — no FM) → insert as a
/// `source == .autoLogged` `Transaction` (so it shows in the "N auto-logged —
/// review" chip exactly like an Apple-Pay capture) → `DedupService.flagIfDuplicate`
/// (P8) flags a cross-source collision (manual/voice/share) without ever blocking.
///
/// Two dedup layers, deliberately distinct:
///  1. **Bank-native, no-double-insert:** each transaction's stable bank key
///     (`transactionId` → `internalTransactionId` → a synthetic booking-date/amount/
///     counterparty fingerprint) is embedded in `rawTranscript`; a re-pull over an
///     overlapping window skips anything already imported. This is what guarantees
///     "second pull → no double-insert".
///  2. **Cross-source, P8:** `DedupService.flagIfDuplicate` flags (never drops) the
///     SAME real payment arriving from a different surface. NOTE (risk): a bank row
///     and an Apple-Pay `.autoLogged` row share the `.autoLoggedIntent` dedup origin
///     (the frozen `DedupOrigin` has no bank case), so those two are not P8-flagged
///     against each other; bank-vs-manual/voice/share/import IS flagged.

// MARK: - Draft + mapper (pure, Sendable)

/// The mapped, source-agnostic shape of one bank transaction before it becomes a
/// `Transaction`. Amount is a magnitude + direction (never a signed `Double`).
struct BankDraft: Equatable, Sendable {
    var amount: Decimal
    var direction: TransactionDirection
    var currency: Currency
    var counterparty: String?
    var descriptionText: String
    var date: Date
    /// The stable key used to detect re-pulls of this exact bank transaction.
    var bankKey: String
    /// The verbatim text preserved into `rawTranscript` for future search.
    var rawText: String
}

/// Pure mapping — no SwiftData, no isolation — so field mapping and amount parsing
/// are unit-testable in isolation.
enum BankSyncMapper {

    /// Money parser: the signed STRING (`"-15.30"`, `"+328.18"`, `"12,50"`) → a
    /// magnitude `Decimal` + direction. L4: the sign is stripped first, then the
    /// remaining digit token is routed through `AmountLexer.value(forDigitToken:)`
    /// — the SAME separator-disambiguation core the voice parser and Excel/CSV
    /// import use — instead of a naive comma→dot swap (which misread "1,234" as
    /// 1.234 rather than the thousands-grouped 1234). GoCardless currently emits
    /// plain dot-decimal amounts, so this is behavior-preserving for real inputs;
    /// it only changes (fixes) inputs the naive swap got wrong. Returns nil for a
    /// blank/zero/unparseable value (skipped, never a zero-amount save).
    static func parseAmount(_ raw: String) -> (magnitude: Decimal, direction: TransactionDirection)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var isNegative = false
        if trimmed.hasPrefix("-") {
            isNegative = true
            trimmed.removeFirst()
        } else if trimmed.hasPrefix("+") {
            trimmed.removeFirst()
        }

        guard let magnitude = AmountLexer.value(forDigitToken: trimmed), magnitude != 0 else { return nil }
        let direction: TransactionDirection = isNegative ? .expense : .income
        return (magnitude, direction)
    }

    /// Currency from the amount block's ISO code, falling back to the account
    /// currency, then RON (never invents a currency).
    static func currency(code: String?, accountCurrency: Currency) -> Currency {
        guard let code, !code.isEmpty else { return accountCurrency }
        return Currency(rawValue: code.uppercased()) ?? accountCurrency
    }

    /// The counterparty signal: for a debit (expense) the money went TO the creditor;
    /// for a credit (income) it came FROM the debtor. Falls back to remittance text.
    static func counterparty(from tx: BankTransaction, direction: TransactionDirection) -> String? {
        let primary = direction == .expense ? tx.creditorName : tx.debtorName
        let secondary = direction == .expense ? tx.debtorName : tx.creditorName
        let candidates = [primary, secondary, remittance(from: tx), tx.additionalInformation]
        for candidate in candidates {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        }
        return nil
    }

    /// The unstructured remittance text (single field, else the array joined).
    static func remittance(from tx: BankTransaction) -> String? {
        if let s = tx.remittanceInformationUnstructured?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        if let arr = tx.remittanceInformationUnstructuredArray, !arr.isEmpty {
            let joined = arr.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// The booking date: `bookingDate` (yyyy-MM-dd) → `bookingDateTime` (ISO8601) →
    /// `valueDate` → now. Never crashes on a missing/odd date.
    static func date(from tx: BankTransaction, now: Date = .now) -> Date {
        if let d = tx.bookingDate, let parsed = GoCardlessClient.apiDateFormatter.date(from: d) { return parsed }
        if let dt = tx.bookingDateTime, let parsed = ISO8601DateFormatter().date(from: dt) { return parsed }
        if let v = tx.valueDate, let parsed = GoCardlessClient.apiDateFormatter.date(from: v) { return parsed }
        return now
    }

    /// The stable per-transaction key for re-pull dedup. For id-less banks the
    /// synthetic fingerprint uses the RAW date STRING (never the resolved `now`
    /// fallback), so a date-less row hashes identically on every pull and is not
    /// re-inserted. RISK: two genuinely-identical id-less same-day payments collide
    /// (the second is skipped) — rare, and the safer failure than double-counting.
    static func bankKey(for tx: BankTransaction, counterparty: String?, amountRaw: String, currency: Currency) -> String {
        if let id = tx.transactionId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        if let id = tx.internalTransactionId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        let rawDate = tx.bookingDate ?? tx.bookingDateTime ?? tx.valueDate ?? ""
        return "syn:\(rawDate)|\(amountRaw)|\(currency.rawValue)|\(counterparty ?? "")"
    }

    /// Map one bank transaction to a `BankDraft`, or nil to skip it (unparseable /
    /// zero amount).
    static func draft(from tx: BankTransaction, accountCurrency: Currency, now: Date = .now) -> BankDraft? {
        guard let (magnitude, direction) = parseAmount(tx.transactionAmount.amount) else { return nil }
        let cur = currency(code: tx.transactionAmount.currency, accountCurrency: accountCurrency)
        let party = counterparty(from: tx, direction: direction)
        let when = date(from: tx, now: now)
        let key = bankKey(for: tx, counterparty: party, amountRaw: tx.transactionAmount.amount, currency: cur)
        let description = party ?? remittance(from: tx) ?? String(localized: "bank.tx.fallback")
        // Verbatim text preserved for search (merchant + amount + currency).
        let amountString = NSDecimalNumber(decimal: magnitude).stringValue
        var parts: [String] = []
        if let party { parts.append(party) }
        if let rem = remittance(from: tx), rem != party { parts.append(rem) }
        parts.append("\(amountString) \(cur.displayCode)")
        let rawText = parts.joined(separator: " · ")
        return BankDraft(
            amount: magnitude, direction: direction, currency: cur,
            counterparty: party, descriptionText: description, date: when,
            bankKey: key, rawText: rawText
        )
    }

    // MARK: rawTranscript marker

    /// The `[bank]` origin prefix + the embedded bank-key marker used for re-pull
    /// dedup. Kept `[bank]`-prefixed (NOT `[share]`) so `DedupOrigin` resolves to
    /// `.autoLoggedIntent`, never colliding with real share captures.
    static let originPrefix = "[bank]"

    static func rawTranscript(for draft: BankDraft) -> String {
        "\(originPrefix) \(draft.rawText) \(marker(for: draft.bankKey))"
    }

    static func marker(for bankKey: String) -> String { "⟦bank:\(bankKey)⟧" }

    /// Extract the embedded bank key from a stored `rawTranscript`, or nil.
    static func extractBankKey(from rawTranscript: String?) -> String? {
        guard let raw = rawTranscript,
              let open = raw.range(of: "⟦bank:"),
              let close = raw.range(of: "⟧", range: open.upperBound..<raw.endIndex) else { return nil }
        return String(raw[open.upperBound..<close.lowerBound])
    }
}

// MARK: - Outcome

/// The result of one sync pass — counts only, no secrets.
struct BankSyncOutcome: Equatable, Sendable {
    var inserted: Int = 0
    var skippedDuplicates: Int = 0
    var flaggedCrossSource: Int = 0
    var accountsSynced: Int = 0
    /// True when no credentials were present — the feature was inert (silent-degrade).
    var credentialsMissing: Bool = false
    /// True when a network/decoding failure aborted an account (silently absorbed).
    var hadError: Bool = false

    static let inert = BankSyncOutcome(credentialsMissing: true)
}

// MARK: - Service

@ModelActor
actor BankSyncService {

    /// The overlap re-fetched before the last sync, so late-booked transactions are
    /// not missed. Re-pulled rows are filtered by the bank-key dedup, never
    /// re-inserted.
    static let refetchOverlap: TimeInterval = 3 * 24 * 60 * 60 // 3 days

    /// Pull + land transactions for the given accounts. `annotator` defaults to the
    /// deterministic-only path (no FM on CI). Every failure is absorbed silently —
    /// the outcome reports counts, never throws to the UI.
    func sync(
        accountIDs: [String],
        accountCurrency: Currency = .ron,
        client: GoCardlessClient,
        annotator: any AnnotationRefining = UnavailableAnnotator()
    ) async -> BankSyncOutcome {
        // Silent-degrade: no keys ⇒ inert, no network touched.
        guard client.secrets.hasCredentials else { return .inert }
        guard !accountIDs.isEmpty else { return BankSyncOutcome() }

        var outcome = BankSyncOutcome()

        // Fetch existing state once: category rules + registries for annotation, and
        // every already-imported bank key for the no-double-insert guard.
        //
        // H1/phase-A considered narrowing this to a `source == .autoLogged`
        // `#Predicate` (every bank row is `.autoLogged`; `extractBankKey` already
        // discards non-bank `.autoLogged` rows via the missing marker, so it would
        // be a correct — not just a faster — narrowing). Left as the full fetch:
        // there is no local Swift toolchain to compile-verify a `#Predicate`
        // enum-equality expression here (no existing precedent for it in this
        // codebase — the only other `#Predicate<Transaction>` sites compare `id`;
        // `direction`, the other stored enum, is explicitly documented as "never
        // used in a #Predicate keypath"), and CI is the only gate. Flagged for a
        // worker/session with toolchain access to pick up.
        let ruleSnaps = ruleSnapshots()
        let projectSnaps = projectSnapshots()
        let peopleSnaps = personSnapshots()
        let existing = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        var seenKeys = Set(existing.compactMap { BankSyncMapper.extractBankKey(from: $0.rawTranscript) })

        let linkRow = bankLinkRow()

        for accountID in accountIDs {
            let dateFrom = linkRow?.lastSyncByAccount[accountID].map { $0.addingTimeInterval(-Self.refetchOverlap) }
            let response: AccountTransactionsResponse
            do {
                response = try await client.transactions(accountID: accountID, dateFrom: dateFrom)
            } catch {
                outcome.hadError = true
                continue
            }
            outcome.accountsSynced += 1

            var newestBooking: Date?
            for bankTx in response.transactions.booked ?? [] {
                guard let draft = BankSyncMapper.draft(from: bankTx, accountCurrency: accountCurrency) else { continue }
                newestBooking = max(newestBooking ?? draft.date, draft.date)

                // No-double-insert: skip anything already imported (this run or prior).
                guard !seenKeys.contains(draft.bankKey) else {
                    outcome.skippedDuplicates += 1
                    continue
                }
                seenKeys.insert(draft.bankKey)

                // P10 annotation (deterministic on CI); direction/counterparty stay the
                // bank's ground truth.
                let interpretation = await InterpretationService.annotate(
                    .importRow(draft.descriptionText),
                    rules: ruleSnaps, projects: projectSnaps, people: peopleSnaps,
                    annotator: annotator
                )

                let transaction = Transaction(
                    amount: draft.amount,
                    currency: draft.currency,
                    context: .personal,
                    descriptionText: draft.descriptionText,
                    date: draft.date,
                    rawTranscript: BankSyncMapper.rawTranscript(for: draft),
                    source: .autoLogged,
                    direction: draft.direction,
                    counterparty: draft.counterparty
                )
                transaction.categoryRef = interpretation.categoryRef ?? .preset(.other)
                modelContext.insert(transaction)
                outcome.inserted += 1

                // P8 — flag (never drop) a cross-source duplicate for the review surface.
                if DedupService.flagIfDuplicate(transaction, in: modelContext) != nil {
                    outcome.flaggedCrossSource += 1
                }
            }

            // Since-last-sync bookkeeping.
            if let linkRow, let newestBooking {
                linkRow.lastSyncByAccount[accountID] = max(linkRow.lastSyncByAccount[accountID] ?? .distantPast, newestBooking)
            }
        }

        try? modelContext.save()
        return outcome
    }

    // MARK: Snapshot builders (on the actor's context)

    private func bankLinkRow() -> BankLink? {
        let all = (try? modelContext.fetch(FetchDescriptor<BankLink>())) ?? []
        return all.sorted { $0.createdAt > $1.createdAt }.first
    }

    private func ruleSnapshots() -> [CategoryRuleSnapshot] {
        let rules = (try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? []
        return rules.map { CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, customCategoryID: $0.customCategoryID, origin: $0.origin, hitCount: $0.hitCount) }
    }

    private func projectSnapshots() -> [ProjectSnapshot] {
        ((try? modelContext.fetch(FetchDescriptor<Project>())) ?? []).map(\.snapshot)
    }

    private func personSnapshots() -> [PersonSnapshot] {
        ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).map(\.snapshot)
    }
}
