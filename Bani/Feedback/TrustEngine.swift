import Foundation

/// The deterministic, on-device trust engine (B4) — the "eventually stops asking"
/// math. Operates on a chronological sequence of hit/miss samples for ONE fired
/// category rule (`true` = confirmation, `false` = miss), already extracted from
/// the ledger. Pure value logic, no SwiftData, fully unit-testable.
///
/// A rule earns trust at ≥95% trailing accuracy over its last 20 decisions once
/// it has ≥10 decisions, and LOSES it if trailing accuracy drops below 90%. The
/// hysteresis band (90–95%) is why trust is replayed over the whole history
/// rather than read off the latest window alone.
enum TrustEngine {
    static let window = 20
    static let promoteAccuracy = 0.95
    static let demoteAccuracy = 0.90
    static let minDecisions = 10

    /// Trailing accuracy over the last `window` samples, plus the count actually
    /// considered. `(0, 0)` for an empty history (never a divide-by-zero).
    static func trailingAccuracy(_ samples: [Bool], window: Int = window) -> (accuracy: Double, count: Int) {
        let recent = samples.suffix(window)
        guard !recent.isEmpty else { return (0, 0) }
        let hits = recent.filter { $0 }.count
        return (Double(hits) / Double(recent.count), recent.count)
    }

    /// The current trusted state after replaying the full history with hysteresis:
    /// flip to trusted when (count ≥ `minDecisions` AND trailing ≥ `promoteAccuracy`);
    /// flip back when (trailing < `demoteAccuracy`). Between the two thresholds the
    /// state is held — trust is earned AND losable.
    static func isTrusted(_ samples: [Bool]) -> Bool {
        var trusted = false
        for endIndex in samples.indices {
            let prefix = Array(samples[...endIndex])
            let (accuracy, count) = trailingAccuracy(prefix)
            if trusted {
                if accuracy < demoteAccuracy { trusted = false }
            } else {
                if count >= minDecisions && accuracy >= promoteAccuracy { trusted = true }
            }
        }
        return trusted
    }
}
