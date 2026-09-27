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

    // NOT `.secondsSince1970`/`timeIntervalSince1970`: `Date` natively stores its
    // interval since the 2001 reference date, not 1970 — round-tripping through
    // `timeIntervalSince1970` adds the 978307200.0 epoch offset on write and
    // subtracts it on read, and that double arithmetic loses a ULP on recent
    // dates. Two `Date`s that PRINT identically then fail exact `Equatable`
    // comparison (`testFailedOutcomeAfterPriorSuccessLeavesTimestampUntouched`,
    // CI run 33258846602) — same bug class as `BackupArchiver`/`BackupRestorer`
    // (commit 56cf7fb). Persisting `timeIntervalSinceReferenceDate` directly is
    // bit-exact, zero-conversion. Key renamed (not just the storage format) so a
    // stale since-1970 `Double` left over from a prior build is never misread as
    // a reference-date interval.
    private static let lastSuccessKey = "bank.sync.lastSuccessRefDate"
    private static let lastHadErrorKey = "bank.sync.lastHadError"
    private static let runsKey = "bank.sync.runs"
    /// v0.3 — how many past runs the history keeps; diagnostics, not data.
    static let maxRuns = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The timestamp of the last sync attempt that did NOT error, or nil if
    /// none has ever succeeded (or the persisted value was cleared).
    var lastSuccessAt: Date? {
        guard let stored = defaults.object(forKey: Self.lastSuccessKey) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: stored)
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
        appendRun(BankSyncRun(at: now, outcome: outcome))
        defaults.set(outcome.hadError, forKey: Self.lastHadErrorKey)
        guard !outcome.hadError else { return }
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: Self.lastSuccessKey)
    }

    // MARK: - v0.3 run history

    /// Every non-inert sync attempt (foreground or manual), newest first, capped
    /// at `maxRuns`. Stored as JSON in the same `UserDefaults` as the gate —
    /// diagnostics only, so deliberately NOT a SwiftData model and NOT part of
    /// the backup archive. `Date` round-trips through JSONEncoder's default
    /// reference-date double: bit-exact, same lesson as `lastSuccessKey`.
    var runs: [BankSyncRun] {
        guard let data = defaults.data(forKey: Self.runsKey),
              let decoded = try? JSONDecoder().decode([BankSyncRun].self, from: data) else { return [] }
        return decoded
    }

    private func appendRun(_ run: BankSyncRun) {
        let kept = Array(([run] + runs).prefix(Self.maxRuns))
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Self.runsKey)
        }
    }
}

/// One recorded sync attempt — see `BankSyncGate.runs`.
struct BankSyncRun: Codable, Equatable, Sendable, Identifiable {
    var at: Date
    var outcome: BankSyncOutcome
    var id: Date { at }
}
