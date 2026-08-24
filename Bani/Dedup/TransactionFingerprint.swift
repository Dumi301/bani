import Foundation

/// Cross-source dedup confidence (P8). The same real payment can land through
/// more than one entry surface — Apple Pay auto-capture, a shared bank
/// notification, a voice log, a manual entry, and (P9) a bank-feed import — and
/// must never be silently double-counted. `TransactionFingerprint` is the pure
/// comparison at the heart of it: given two candidate payments it never touches
/// SwiftData, `source`, or any store — it only says how confident a collision is.
enum DedupConfidence: String, Sendable, Equatable, CaseIterable {
    /// Same amount, same currency, same direction, same calendar day, AND a
    /// fuzzy counterparty/merchant match.
    case exact
    /// Same amount, same currency, same direction, within a ±1 day window —
    /// no counterparty match required (a same-day mismatch also lands here).
    case probable
    /// No collision signal at all.
    case none

    /// Ordering for "pick the best of several candidates" — `exact` beats
    /// `probable` beats `none`.
    var rank: Int {
        switch self {
        case .exact: 2
        case .probable: 1
        case .none: 0
        }
    }
}

/// The dedup-relevant "who logged this" identity — finer-grained than the raw
/// `TransactionSource` alone. `.autoLogged` is ONE frozen-seam `TransactionSource`
/// value shared by BOTH the Apple Pay intent AND a shared bank-notification
/// capture (origin distinguished only by the `rawTranscript` prefix — see
/// `AutoLogPayload.Origin`); those two ARE meant to collide with each other (the
/// same real payment commonly arrives via both), so dedup's "different source"
/// rule must key off this finer origin, not the raw enum case.
enum DedupOrigin: Equatable, Sendable {
    case voice
    case manual
    case imported
    case autoLoggedIntent
    case autoLoggedShare

    /// Derives the dedup origin from a transaction's stored `source` +
    /// `rawTranscript` prefix (the ONLY place intent vs. share is recorded).
    static func of(source: TransactionSource, rawTranscript: String?) -> DedupOrigin {
        switch source {
        case .voice: return .voice
        case .manual: return .manual
        case .imported: return .imported
        case .autoLogged:
            if let rawTranscript, rawTranscript.hasPrefix(AutoLogPayload.Origin.share.prefix) {
                return .autoLoggedShare
            }
            return .autoLoggedIntent
        }
    }
}

/// Pure, source-blind fingerprint comparison over (amount, currency, direction,
/// date, counterparty/merchant). Deliberately EXCLUDES `source` — the whole
/// point is that a collision is judged by "does this look like the same real
/// payment", never by which surface logged it. `DedupService` is the SwiftData
/// bridge (fetch + flag); this file has no store dependency at all.
enum TransactionFingerprint {

    /// The comparable shape of one payment — built from a persisted
    /// `Transaction`, an import `DraftTransaction`, or any other candidate
    /// shape a caller has in hand.
    struct Key: Sendable, Equatable {
        var amount: Decimal
        var currency: Currency
        var direction: TransactionDirection
        var date: Date
        /// The best available counterparty signal, RAW (not yet normalized —
        /// `counterpartyFuzzyMatches` folds it). Falls back merchant →
        /// counterparty → description at the call site (see `key(for:)`).
        var counterparty: String

        init(amount: Decimal, currency: Currency, direction: TransactionDirection, date: Date, counterparty: String) {
            self.amount = amount
            self.currency = currency
            self.direction = direction
            self.date = date
            self.counterparty = counterparty
        }
    }

    /// Builds a `Key` from a persisted `Transaction`. Counterparty preference:
    /// explicit `counterparty` → `merchant` → `descriptionText` (always
    /// present, the loosest but never-blank signal).
    static func key(for transaction: Transaction) -> Key {
        Key(
            amount: transaction.amount,
            currency: transaction.currency,
            direction: transaction.direction,
            date: transaction.date,
            counterparty: counterpartySignal(
                counterparty: transaction.counterparty,
                merchant: transaction.merchant,
                description: transaction.descriptionText
            )
        )
    }

    /// The counterparty/merchant/description preference chain, shared by every
    /// caller building a `Key` (persisted transactions AND import drafts) so
    /// the signal choice never drifts between the two.
    static func counterpartySignal(counterparty: String?, merchant: String?, description: String) -> String {
        if let counterparty, !counterparty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return counterparty }
        if let merchant, !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return merchant }
        return description
    }

    /// Calendar-day distance in the CURRENT timezone (matching `ImportFingerprint`'s
    /// day-granularity convention), so a payment logged at 23:50 and one logged at
    /// 00:10 the next real-world moment are compared by calendar day, not by a raw
    /// 24h-second cutoff.
    static func dayDistance(_ a: Date, _ b: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let da = cal.startOfDay(for: a)
        let db = cal.startOfDay(for: b)
        return abs(cal.dateComponents([.day], from: da, to: db).day ?? Int.max)
    }

    /// Fuzzy counterparty/merchant match via `Categorizer.normalize` (fold +
    /// lowercase) then a prefix match of the shorter normalized string against
    /// the longer — so "Lidl" matches "Lidl Cluj", "MEGA IMAGE" matches
    /// "Mega Image Titan", etc. Two blank signals never match (no signal at all
    /// is not a match).
    static func counterpartyFuzzyMatches(_ a: String, _ b: String) -> Bool {
        let na = Categorizer.normalize(a).trimmingCharacters(in: .whitespacesAndNewlines)
        let nb = Categorizer.normalize(b).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let (shorter, longer) = na.count <= nb.count ? (na, nb) : (nb, na)
        return longer.hasPrefix(shorter)
    }

    /// The confidence tier for one pair. `amount` + `currency` + `direction`
    /// must ALL match exactly for either tier — a mismatched direction (an
    /// expense vs. a neutral transfer of the same amount) is never a collision,
    /// whatever the date or name. Within that: same calendar day + a fuzzy
    /// counterparty match → `exact`; any pairing within the ±1 day window →
    /// `probable`; otherwise `none`.
    static func confidence(_ a: Key, _ b: Key) -> DedupConfidence {
        guard a.amount == b.amount, a.currency == b.currency, a.direction == b.direction else { return .none }
        let distance = dayDistance(a.date, b.date)
        guard distance <= 1 else { return .none }
        if distance == 0 && counterpartyFuzzyMatches(a.counterparty, b.counterparty) { return .exact }
        return .probable
    }
}
