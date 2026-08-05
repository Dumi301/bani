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

    /// Import-path plausibility ceiling: a magnitude strictly above this is almost
    /// certainly float-dust / a mis-parse, never a real RON/EUR amount (matches the
    /// voice parser's `amountGuardrailMax`). Surfaced as `implausibleAmount`.
    static let plausibilityCap = Decimal(100_000_000)

    static func isPureDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }

    /// Round a `Decimal` to 2 fraction digits (money), half away from zero. Used to
    /// tame Excel float-dust (`34839.699999999997` → `34839.70`) and long decimal
    /// tails (`12.3456` → `12.35`) into clean money values.
    static func roundedMoney(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
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
            // PINNED — do not change.
            var s = clean; s.removeAll { $0 == sep }
            return Decimal(string: s, locale: posix)
        case 1, 2:
            // B1c: 1–2 trailing digits → decimal separator ("12,50", "12.5").
            // PINNED — do not change.
            return Decimal(string: clean.replacingOccurrences(of: String(sep), with: "."), locale: posix)
        case 0:
            // Trailing separator with no fraction ("1234.") → malformed grouping;
            // best-effort plain digits, separator stripped.
            var s = clean; s.removeAll { $0 == sep }
            return Decimal(string: s, locale: posix)
        default:
            // B1d (REPLACED): ≥4 trailing digits is float-dust / a genuine long
            // decimal tail, NOT thousands. Excel stores displayed "34.839,70" as
            // "34839.699999999997"; the old rule stripped the "." → a phantom
            // 34_839_699_999_999_997. Treat the single separator as the DECIMAL
            // point and round to 2dp money ("34839.699999999997" → 34839.70,
            // "12.3456" → 12.35). Multi-separator thousands ("1.234.567") and the
            // 3-trailing thousands rule ("25.000") are handled above, unchanged.
            let asDecimal = Decimal(string: clean.replacingOccurrences(of: String(sep), with: "."), locale: posix)
            return asDecimal.map(roundedMoney)
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

    /// The outcome of classifying a free-form amount cell. `.implausible` lets the
    /// import surface a distinct `implausibleAmount` skip reason (never a silent
    /// commit, never a silent drop) instead of collapsing to `.none`.
    enum CellAmount: Equatable, Sendable {
        case value(Amount)      // a clean, plausible magnitude
        case implausible        // parsed but above the plausibility cap
        case none               // no numeric core / multi-number / zero
    }

    /// Parses a free-form amount cell into a non-negative magnitude + a sign flag,
    /// or `nil` when it is not a single plausible amount. Thin wrapper over
    /// `classifyCell` for the string-cell callers (family parsers, voice-adjacent);
    /// an implausible or multi-number cell reads as `nil` (skipped). The import row
    /// parser calls `classifyCell` directly so it can distinguish the reasons.
    static func parseCell(_ raw: String) -> Amount? {
        if case .value(let a) = classifyCell(raw) { return a }
        return nil
    }

    /// Full classification of a free-form amount cell ("1.234,56", "25.000",
    /// "-25,00", "(25,00)", "1 234,56", "50 lei", "€12.5", "3.4E7"). Strips a
    /// leading/trailing currency word or symbol and space grouping, detects
    /// negativity (leading minus / accounting parentheses), handles scientific
    /// notation, REJECTS multi-number cells ("1.200 + 300"), and caps implausible
    /// magnitudes. Never invents a number; never concatenates two numbers.
    static func classifyCell(_ raw: String) -> CellAmount {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .none }

        // Accounting negatives: "(25,00)" → negative.
        var isNegative = false
        if s.first == "(" && s.last == ")" {
            isNegative = true
            s.removeFirst(); s.removeLast()
        }
        if s.contains("-") || s.contains("\u{2212}") { isNegative = true }

        // Scientific notation FIRST — before the letter-stripping loop, which would
        // otherwise drop the "E" and merge the mantissa+exponent digits into a
        // bogus integer ("3.4E7" → "3.47"). Excel emits E-notation for large/small
        // numeric cells written as text.
        if let sci = scientificValue(s) {
            return finish(magnitude: sci, isNegative: isNegative)
        }

        // Multi-number guard: two or more digit groups separated by a character
        // that is NOT a decimal/thousands separator, space or sign (e.g. "+", "/",
        // letters between numbers) is ambiguous — never concatenate. ("1.200 + 300"
        // → nil, not 1200300.) Space-grouped thousands ("1 234 567") stays ONE
        // group. This runs after the sci check so "3.4E7" is not split on "E".
        let numberGroups = s.split(whereSeparator: { ch in
            !(ch.isNumber || ch == "." || ch == "," || ch == " " || ch == "\u{00A0}"
              || ch == "-" || ch == "\u{2212}")
        }).filter { $0.contains(where: \.isNumber) }
        if numberGroups.count >= 2 { return .none }

        // Strip everything that is not a digit or separator so a stray currency
        // word/symbol ("lei", "RON", "€", "$") and signs fall away.
        var core = ""
        for ch in s where ch.isNumber || ch == "," || ch == "." { core.append(ch) }

        guard !core.isEmpty else { return .none }
        guard let value = value(forDigitToken: core) else { return .none }
        return finish(magnitude: value, isNegative: isNegative)
    }

    /// Classify an already-numeric value (an xlsx numeric cell resolved by
    /// `XLSXReader`): round to money, drop zero, cap implausible. Sign is carried
    /// from the value itself; magnitude is the absolute value.
    static func classify(numeric value: Decimal) -> CellAmount {
        finish(magnitude: value, isNegative: value < 0)
    }

    /// Shared tail: round to 2dp money, reject zero, cap implausible, otherwise a
    /// clean value. `magnitude` may arrive signed; it is made absolute here.
    private static func finish(magnitude raw: Decimal, isNegative: Bool) -> CellAmount {
        let rounded = roundedMoney(raw)
        let magnitude = rounded < 0 ? -rounded : rounded
        // A pure-zero magnitude is a non-amount (blank/0 cell).
        guard magnitude > 0 else { return .none }
        // Plausibility cap: > 100,000,000 is float-dust / a mis-parse, never a real
        // amount — surfaced as `implausibleAmount`, never silently committed.
        guard magnitude <= plausibilityCap else { return .implausible }
        return .value(Amount(magnitude: magnitude, isNegative: isNegative))
    }

    /// If `s` is (or contains) a scientific-notation numeric literal, its value as
    /// a non-negative `Decimal` (magnitude; sign handled by the caller); else nil.
    /// Uses `Double` on purpose — the exponent form only exists for numeric cells.
    private static func scientificValue(_ s: String) -> Decimal? {
        let pattern = "[0-9]+(?:[.,][0-9]+)?[eE][+-]?[0-9]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let token = ns.substring(with: m.range).replacingOccurrences(of: ",", with: ".")
        guard let d = Double(token) else { return nil }
        return Decimal(d < 0 ? -d : d)
    }
}
