import Foundation
import SwiftData

/// P9 / v2.3 — pulls booked bank transactions from Enable Banking (via
/// `EnableBankingClient`, the Bani worker's pass-through) and lands them in the
/// EXISTING auto-log review flow. Runs off the main actor (`@ModelActor`, its own
/// `ModelContext` over the shared store — the `ImportCommitRunner` pattern) so a
/// foreground/manual sync never blocks the UI.
///
/// Pipeline per transaction: decode → filter to `status == "BOOK"` (a `PEND` row
/// is never landed — it can still change or vanish before it books) → map to a
/// `BankDraft` (`Decimal` magnitude from the UNSIGNED amount string via
/// `AmountLexer`, direction from `credit_debit_indicator`, counterparty from
/// creditor/debtor, date from `booking_date`) → annotate the category via P10's
/// `InterpretationService` (deterministic on CI — no FM) → insert as a
/// `source == .autoLogged` `Transaction` (so it shows in the "N auto-logged —
/// review" chip exactly like an Apple-Pay capture) → `DedupService.flagIfDuplicate`
/// (P8) flags a cross-source collision (manual/voice/share) without ever blocking.
///
/// Two dedup layers, deliberately distinct:
///  1. **Bank-native, no-double-insert:** each transaction's stable bank key
///     (`transaction_id` → `entry_reference` → a synthetic booking-date/amount/
///     counterparty fingerprint) is embedded in `rawTranscript`; a re-pull over an
///     overlapping window skips anything already imported. This is what guarantees
///     "second pull → no double-insert". The synthetic-fingerprint FORMAT is
///     unchanged from the pre-v2.3 (GoCardless) mapper — only which raw fields
///     feed it changed — so an old-era `⟦bank:…⟧` marker embedded in a pre-v2.3
///     row is read by the SAME `extractBankKey` and never collides with a v2.3
///     row unless the underlying transaction data itself is identical.
///  2. **Cross-source, P8:** `DedupService.flagIfDuplicate` flags (never drops) the
///     SAME real payment arriving from a different surface. `DedupOrigin` DOES carry
///     a dedicated `.bank` case (`[bank]`-prefixed `rawTranscript` resolves to it —
///     see `DedupOrigin.of`), distinct from `.autoLoggedIntent` (Apple Pay) and
///     `.autoLoggedShare` — so a bank row and an Apple-Pay `.autoLogged` row ARE
///     cross-source flagged against each other, exactly like bank-vs-manual/voice/
///     share/import. `DedupOrigin`'s own doc explains why: intent, share, and bank
///     are each meant to collide with EACH OTHER (the same real payment commonly
///     arrives via more than one surface).
///
/// v2.3 pagination: Enable Banking pages transactions via an opaque
/// `continuation_key` cursor instead of GoCardless's single flat `booked`/`pending`
/// arrays. `sync` walks the cursor per account, bounded at
/// `maxPagesPerAccount` so a misbehaving feed can never turn one sync into an
/// unbounded pull.
///
/// v2.3 revocation: a 401/403 from `transactions` mid-life marks the link's
/// `sessionRevoked = true` (defensively both codes — Enable Banking's exact
/// revocation status code is unverified) so `BankLinkState.derive` reports
/// `.expired` and the UI prompts a re-link; the sync itself still reports the
/// account as errored (`hadError`), never crashes, never blocks other accounts.

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

    /// General-purpose SIGNED-string amount parser (`"-15.30"`, `"+328.18"`,
    /// `"12,50"`) → a magnitude `Decimal` + direction inferred from the sign.
    /// NOT used by `draft(from:)` below — Enable Banking's amounts are UNSIGNED
    /// (see `magnitude(fromUnsignedAmount:)`), so applying this sign-stripping
    /// parser to one would silently mis-infer `.income` for every row (no sign
    /// is ever present to strip). Kept as a standalone utility, still exercised
    /// by its own tests: the separator-disambiguation core
    /// (`AmountLexer.value(forDigitToken:)`) it shares with the voice parser and
    /// Excel/CSV import is worth pinning independently of any one bank feed's
    /// sign convention.
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

    /// Enable Banking's `transaction_amount.amount` is UNSIGNED — direction is
    /// carried separately by `credit_debit_indicator` (see `direction(from:)`),
    /// never by a sign in this string. Magnitude alone goes through
    /// `AmountLexer.value(forDigitToken:)` directly, with NO sign-stripping
    /// step (there is never a sign to strip) — the SAME separator-disambiguation
    /// core the voice parser and Excel/CSV import use, so a bank feed that
    /// writes thousands with a dot ("25.000") is still read correctly. Returns
    /// nil for a blank/zero/unparseable value (skipped, never a zero-amount save).
    static func magnitude(fromUnsignedAmount raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = AmountLexer.value(forDigitToken: trimmed), value != 0 else { return nil }
        return value
    }

    /// `DBIT` = money left the account (expense); anything else (`CRDT`, or an
    /// unrecognized code — tolerant by design) is treated as income.
    static func direction(from creditDebitIndicator: String) -> TransactionDirection {
        creditDebitIndicator == "DBIT" ? .expense : .income
    }

    /// Currency from the amount block's ISO code, falling back to the account
    /// currency, then RON (never invents a currency).
    static func currency(code: String?, accountCurrency: Currency) -> Currency {
        guard let code, !code.isEmpty else { return accountCurrency }
        return Currency(rawValue: code.uppercased()) ?? accountCurrency
    }

    /// The counterparty signal: for a debit (expense) the money went TO the
    /// creditor; for a credit (income) it came FROM the debtor. Falls back to
    /// the remittance text.
    static func counterparty(from tx: EBTransaction, direction: TransactionDirection) -> String? {
        let primary = direction == .expense ? tx.creditor?.name : tx.debtor?.name
        let secondary = direction == .expense ? tx.debtor?.name : tx.creditor?.name
        let candidates = [primary, secondary, remittance(from: tx)]
        for candidate in candidates {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        }
        return nil
    }

    /// The unstructured remittance text — Enable Banking's `remittance_information`
    /// is already `[String]?`, joined for display.
    static func remittance(from tx: EBTransaction) -> String? {
        guard let arr = tx.remittanceInformation, !arr.isEmpty else { return nil }
        let joined = arr.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// The booking date: `booking_date` → `value_date` → `transaction_date` →
    /// now. Never crashes on a missing/odd date.
    static func date(from tx: EBTransaction, now: Date = .now) -> Date {
        if let d = tx.bookingDate, let parsed = EnableBankingClient.apiDateFormatter.date(from: d) { return parsed }
        if let v = tx.valueDate, let parsed = EnableBankingClient.apiDateFormatter.date(from: v) { return parsed }
        if let t = tx.transactionDate, let parsed = EnableBankingClient.apiDateFormatter.date(from: t) { return parsed }
        return now
    }

    /// The stable per-transaction key for re-pull dedup: primary `transaction_id`,
    /// secondary `entry_reference`, else a synthetic fingerprint. The SYNTHETIC
    /// FORMAT itself is unchanged from the pre-v2.3 (GoCardless) mapper — only
    /// which raw fields feed it changed — so it still uses the RAW date STRING
    /// (never the resolved `now` fallback), so a date-less row hashes
    /// identically on every pull and is not re-inserted. RISK: two genuinely-
    /// identical id-less same-day payments collide (the second is skipped) —
    /// rare, and the safer failure than double-counting.
    static func bankKey(for tx: EBTransaction, counterparty: String?, amountRaw: String, currency: Currency) -> String {
        if let id = tx.transactionId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        if let id = tx.entryReference?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        let rawDate = tx.bookingDate ?? tx.valueDate ?? tx.transactionDate ?? ""
        return "syn:\(rawDate)|\(amountRaw)|\(currency.rawValue)|\(counterparty ?? "")"
    }

    /// Map one bank transaction to a `BankDraft`, or nil to skip it (unparseable /
    /// zero amount). Caller is responsible for the `status == "BOOK"` filter —
    /// this never inspects `status` itself.
    static func draft(from tx: EBTransaction, accountCurrency: Currency, now: Date = .now) -> BankDraft? {
        guard let mag = magnitude(fromUnsignedAmount: tx.transactionAmount.amount) else { return nil }
        let dir = direction(from: tx.creditDebitIndicator)
        let cur = currency(code: tx.transactionAmount.currency, accountCurrency: accountCurrency)
        let party = counterparty(from: tx, direction: dir)
        let when = date(from: tx, now: now)
        let key = bankKey(for: tx, counterparty: party, amountRaw: tx.transactionAmount.amount, currency: cur)
        let description = party ?? remittance(from: tx) ?? String(localized: "bank.tx.fallback")
        // Verbatim text preserved for search (merchant + amount + currency).
        let amountString = NSDecimalNumber(decimal: mag).stringValue
        var parts: [String] = []
        if let party { parts.append(party) }
        if let rem = remittance(from: tx), rem != party { parts.append(rem) }
        parts.append("\(amountString) \(cur.displayCode)")
        let rawText = parts.joined(separator: " · ")
        return BankDraft(
            amount: mag, direction: dir, currency: cur,
            counterparty: party, descriptionText: description, date: when,
            bankKey: key, rawText: rawText
        )
    }

    // MARK: rawTranscript marker

    /// The `[bank]` origin prefix + the embedded bank-key marker used for re-pull
    /// dedup. Kept `[bank]`-prefixed (NOT `[share]`) so `DedupOrigin` resolves to its
    /// own dedicated `.bank` case (see `DedupOrigin.of`) rather than being mistaken
    /// for a share capture — `.bank` still cross-source-collides with
    /// `.autoLoggedShare`/`.autoLoggedIntent`/manual/voice/import, just not with
    /// another `.bank` row (that re-pull guard is the bank-key marker below, not P8).
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

    /// v2.3 pagination guard: Enable Banking's `continuation_key` walk is
    /// unbounded in principle. This caps how many pages ONE account will page
    /// through in ONE sync so a misbehaving feed (or an infinite-key ASPSP
    /// quirk) can never turn one sync into an unbounded pull.
    static let maxPagesPerAccount = 20

    /// Pull + land transactions for the given accounts. `annotator` defaults to the
    /// deterministic-only path (no FM on CI). Every failure is absorbed silently —
    /// the outcome reports counts, never throws to the UI.
    func sync(
        accountIDs: [String],
        accountCurrency: Currency = .ron,
        client: EnableBankingClient,
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
            var newestBooking: Date?
            var accountSucceeded = false
            var continuationKey: String?

            pageLoop: for _ in 0..<Self.maxPagesPerAccount {
                let page: TransactionsPage
                do {
                    page = try await client.transactions(
                        accountUID: accountID, dateFrom: dateFrom, continuationKey: continuationKey
                    )
                } catch let error as EnableBankingError {
                    outcome.hadError = true
                    // Defensively both codes — Enable Banking's exact
                    // revocation status code from `transactions` is unverified.
                    if error == .unauthorized {
                        linkRow?.sessionRevoked = true
                    } else if case .http(403, _) = error {
                        linkRow?.sessionRevoked = true
                    }
                    break pageLoop
                } catch {
                    outcome.hadError = true
                    break pageLoop
                }

                accountSucceeded = true

                for bankTx in page.transactions where bankTx.status == "BOOK" {
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

                guard let nextKey = page.continuationKey, !nextKey.isEmpty else { break pageLoop }
                continuationKey = nextKey
            }

            if accountSucceeded { outcome.accountsSynced += 1 }

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
