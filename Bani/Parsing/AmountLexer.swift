import Foundation

/// Shared numeric-amount lexer. The separator-disambiguation core
/// (`value(forDigitToken:)`) was EXTRACTED VERBATIM from `RuleBasedParser`'s
/// former `digitValue(_:)` so exactly one implementation decides whether a "." or
/// "," is a decimal mark or a thousands separator — the voice parser and the
/// Excel/CSV import now agree, byte-for-byte, and `ParserTests` still pins the
/// behavior.
///
/// Pure value logic, `Sendable`, safe from any isolation context.
enum AmountLexer {

    /// `en_US_POSIX` so `Decimal(string:)` always reads "." as the decimal point,
    /// regardless of the device locale.
    static let posix = Locale(identifier: "en_US_POSIX")

    static func isPureDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }

    // MARK: - Separator-disambiguation core (moved from RuleBasedParser.digitValue)

    /// Converts a single numeric token to a `Decimal`, disambiguating "." / ","
    /// as decimal marks vs thousands separators (B1). Romanian speech-to-text and
    /// spreadsheets alike write thousands with a dot ("25.000"), so a naive
    /// comma→dot swap is wrong. The token must already be digits + "," + "." only.
    static func value(forDigitToken clean: String) -> Decimal? {
        guard !clean.isEmpty else { return nil }
        guard clean.contains(where: { $0.isNumber }) else { return nil }
        guard clean.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) else { return nil }

        let hasDot = clean.contains(".")
        let hasComma = clean.contains(",")

        // Plain integer — no separators.
        if !hasDot && !hasComma {
            return Decimal(string: clean, locale: posix)
        }

        // B1a: BOTH separators present → the LAST one (by position) is the decimal
        // mark; every other separator is thousands grouping and is stripped.
        // "1.234,56" → 1234.56 · "1,234.56" → 1234.56
        if hasDot && hasComma {
            let decimalIsDot = clean.lastIndex(of: ".")! > clean.lastIndex(of: ",")!
            let thousands: Character = decimalIsDot ? "," : "."
            var s = clean
            s.removeAll { $0 == thousands }
            if !decimalIsDot { s = s.replacingOccurrences(of: ",", with: ".") }
            return Decimal(string: s, locale: posix)
        }

        // Single separator kind.
        let sep: Character = hasDot ? "." : ","
        let occurrences = clean.reduce(into: 0) { if $1 == sep { $0 += 1 } }

        // B1d: multiple identical separators → thousands grouping ("1.234.567").
        if occurrences > 1 {
            var s = clean; s.removeAll { $0 == sep }
            return Decimal(string: s, locale: posix)
        }

        // Exactly one separator — decide by the length of the trailing group.
        let parts = clean.split(separator: sep, omittingEmptySubsequences: false)
        let afterCount = parts.count == 2 ? parts[1].count : 0
        switch afterCount {
        case 3:
            // B1b: exactly 3 trailing digits → thousands ("25.000" → 25000,
            // "1.000" → 1000). RON/EUR amounts never carry exactly 3 decimals.
            var s = clean; s.removeAll { $0 == sep }
            return Decimal(string: s, locale: posix)
        case 1, 2:
            // B1c: 1–2 trailing digits → decimal separator ("12,50", "12.5").
            return Decimal(string: clean.replacingOccurrences(of: String(sep), with: "."), locale: posix)
        default:
            // B1d: malformed grouping (≥4 or 0 trailing digits, e.g. "12.3456") →
            // best-effort plain digits, separators stripped; never nil-out an
            // obviously numeric token.
            var s = clean; s.removeAll { $0 == sep }
            return Decimal(string: s, locale: posix)
        }
    }

    // MARK: - Import-facing free-form cell parsing

    /// The parsed magnitude of a spreadsheet/CSV amount cell, plus whether it was
    /// written as a negative. Import treats negatives per a per-file policy
    /// (`abs` or skip); the lexer only reports the fact.
    struct Amount: Equatable, Sendable {
        let magnitude: Decimal   // always ≥ 0
        let isNegative: Bool
    }

    /// Parses a free-form amount cell ("1.234,56", "25.000", "-25,00", "(25,00)",
    /// "1 234,56", "50 lei", "€12.5") into a non-negative magnitude + a sign flag.
    /// Strips a leading/trailing currency word or symbol, internal spaces
    /// (space-grouped thousands), and detects negativity from a leading minus or
    /// accounting parentheses. Returns `nil` when no numeric core survives — the
    /// import then skips the row with an "unparseable amount" reason. Never
    /// invents a number.
    static func parseCell(_ raw: String) -> Amount? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Accounting negatives: "(25,00)" → negative. A leading "-" / Unicode
        // minus "−" is also negative.
        var isNegative = false
        if s.first == "(" && s.last == ")" {
            isNegative = true
            s.removeFirst(); s.removeLast()
        }
        // Strip everything that is not a digit, separator, or sign so a stray
        // currency word/symbol ("lei", "RON", "€", "$") falls away. Keep "," "."
        // and "-"/"−" for now.
        var core = ""
        for ch in s {
            if ch.isNumber || ch == "," || ch == "." || ch == "-" || ch == "\u{2212}" {
                core.append(ch)
            }
            // spaces and any other character (letters, currency symbols) are dropped
        }
        // Sign: a minus anywhere in the (now compact) core marks a negative; then
        // remove all sign characters before disambiguation.
        if core.contains("-") || core.contains("\u{2212}") { isNegative = true }
        core.removeAll { $0 == "-" || $0 == "\u{2212}" }

        guard !core.isEmpty else { return nil }
        guard let value = value(forDigitToken: core) else { return nil }
        // A pure-zero magnitude is a non-amount (blank/0 cell) — skip it.
        guard value > 0 else { return nil }
        return Amount(magnitude: value, isNegative: isNegative)
    }
}
