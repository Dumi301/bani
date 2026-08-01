import Foundation

/// Batch-level dedup guard (D). A row fingerprint is `day + amount + normalized
/// description`; importing the same file twice would reproduce ~all of the same
/// fingerprints, so if ≥ `threshold` of an incoming batch's fingerprints already
/// exist among previously-imported transactions, the wizard WARNS before writing
/// (advisory only — legit duplicate expenses exist, so there is NO per-row silent
/// dedup).
enum ImportFingerprint {

    /// The warning threshold — ≥ 80% overlap looks like a re-import.
    static let threshold = 0.80

    /// Day granularity so a re-import whose times drift (or were noon-normalized)
    /// still matches. Uses the current calendar, matching how rows are stored.
    static func fingerprint(date: Date, amount: Decimal, description: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let amountKey = NSDecimalNumber(decimal: amount).stringValue
        let desc = normalizedDescription(description)
        return "\(day)|\(amountKey)|\(desc)"
    }

    /// Fold + lowercase + collapse internal whitespace (so "Lidl  Cluj" and
    /// "lidl cluj" fingerprint identically).
    static func normalizedDescription(_ s: String) -> String {
        let folded = Categorizer.normalize(s)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The overlap ratio of `incoming` fingerprints already present in `existing`.
    /// 0 when there are no incoming rows.
    static func overlapRatio(incoming: [String], existing: Set<String>) -> Double {
        guard !incoming.isEmpty else { return 0 }
        let hits = incoming.reduce(into: 0) { acc, fp in if existing.contains(fp) { acc += 1 } }
        return Double(hits) / Double(incoming.count)
    }

    /// Whether the overlap meets the re-import warning threshold.
    static func looksAlreadyImported(incoming: [String], existing: Set<String>) -> Bool {
        overlapRatio(incoming: incoming, existing: existing) >= threshold
    }
}
