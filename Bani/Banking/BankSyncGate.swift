import Foundation

/// H1 — throttles the opportunistic FOREGROUND bank pull to at most once per
/// `minInterval`, and persists enough about the last attempt to drive the
/// settings status line. GoCardless allows ~4 transaction-endpoint calls per
/// account per day; unthrottled, a few app foregrounds in a row exhaust that
/// quota and the 429 gets silently absorbed into `BankSyncOutcome.hadError`
/// (see `BankSyncService.sync`) — the feed then goes dark for the rest of the
/// day with no visible symptom.
///
/// Mirrors `RateService.refreshIfNeeded`'s last-fetch-timestamp gate, but as a
/// plain `UserDefaults`-injectable type (not `@AppStorage`) so it is usable
/// outside a SwiftUI view context (from `BaniApp.syncBankIfNeeded`) and
/// directly unit-testable (`BankSyncThrottleTests`) without a live view host.
///
/// Manual, user-triggered syncs (`BankLinkView.syncNow()`) never consult
/// `shouldSync` — "Sync now" always runs — but DO call `recordOutcome` so the
/// settings status line reflects manual attempts too.
struct BankSyncGate {

    /// ≤4 GoCardless transaction-endpoint calls/account/day ⇒ a floor of 6h
    /// between opportunistic pulls keeps every foreground-triggered sync
    /// safely inside quota.
    static let minInterval: TimeInterval = 6 * 60 * 60

    private static let lastSuccessKey = "bank.sync.lastSuccessAt"
    private static let lastHadErrorKey = "bank.sync.lastHadError"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The timestamp of the last sync attempt that did NOT error, or nil if
    /// none has ever succeeded (or the persisted value was cleared).
    var lastSuccessAt: Date? {
        let stored = defaults.double(forKey: Self.lastSuccessKey)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    /// Whether the MOST RECENT sync attempt (foreground or manual) ended in
    /// `hadError`. Display-only — the settings status line reads this; it is
    /// never consulted by `shouldSync`.
    var lastHadError: Bool {
        defaults.bool(forKey: Self.lastHadErrorKey)
    }

    /// Whether an opportunistic (foreground) sync should run now.
    func shouldSync(now: Date = .now) -> Bool {
        guard let lastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= Self.minInterval
    }

    /// Record the outcome of a sync attempt (gated or manual). A
    /// `credentialsMissing` (inert) outcome means nothing actually ran and is
    /// ignored entirely. Otherwise `lastHadError` always reflects THIS
    /// attempt; only a non-error attempt advances `lastSuccessAt` — a failed
    /// attempt (network error, 429, …) leaves it untouched so the very next
    /// foreground retries immediately instead of waiting out the full window
    /// on top of the failure.
    func recordOutcome(_ outcome: BankSyncOutcome, now: Date = .now) {
        guard !outcome.credentialsMissing else { return }
        defaults.set(outcome.hadError, forKey: Self.lastHadErrorKey)
        guard !outcome.hadError else { return }
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastSuccessKey)
    }
}
