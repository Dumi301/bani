import Foundation

/// Detects the date column's format from its sample values and parses individual
/// date cells (C2). Two responsibilities kept together because they share the
/// notion of "what shape is this date":
///   • `detect(...)` picks an `ImportDateFormat` and flags day/month ambiguity,
///   • `parse(cell:format:)` turns one cell into a `Date`.
///
/// Pure value logic, `Sendable`.
enum DateFieldParser {

    struct Detection: Equatable, Sendable {
        var format: ImportDateFormat
        /// True when the values can't distinguish day-first from month-first
        /// (all slash dates with both leading numbers ≤ 12) — the wizard then
        /// forces an explicit choice, defaulting to day-first (Romanian reality).
        var ambiguous: Bool
    }

    /// Fixed, locale-independent formatter so parsing is deterministic on any
    /// device. UTC-free: we keep the current calendar/timezone for wall-clock
    /// dates, matching how the app stores voice/manual entries.
    static func makeFormatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        f.isLenient = false
        return f
    }

    // MARK: - Detection

    /// Detect from up to `sampleLimit` non-empty samples. `hasSerialDates` is true
    /// when the (xlsx) column already resolved numeric date-formatted cells.
    static func detect(samples: [SheetCell], sampleLimit: Int = 40) -> Detection {
        let cells = samples.filter { !$0.isEmpty }.prefix(sampleLimit)

        // xlsx already resolved these as real dates → serial, unambiguous.
        if cells.contains(where: { $0.serialDate != nil }) {
            return Detection(format: .excelSerial, ambiguous: false)
        }

        let texts = cells.map(\.text)
        guard !texts.isEmpty else { return Detection(format: .dayFirstDot, ambiguous: false) }

        // ISO: starts with 4 digits then a dash.
        if texts.allSatisfy({ isISO($0) }) {
            return Detection(format: .iso, ambiguous: false)
        }

        // Determine the dominant separator.
        let dotCount = texts.filter { $0.contains(".") }.count
        let slashCount = texts.filter { $0.contains("/") }.count
        let dashCount = texts.filter { $0.contains("-") && !isISO($0) }.count

        if dotCount >= slashCount && dotCount >= dashCount && dotCount > 0 {
            // Dot dates in Romania are day-first; disambiguate only if a sample
            // proves month-first (first component > 12).
            return Detection(format: dayOrMonthFirst(texts, separator: "."), ambiguous: false)
        }
        if dashCount > 0 && dashCount >= slashCount {
            // Non-ISO dash dates ("31-12-2024"): order matters, separator doesn't
            // (parse tries all separators), so reuse the slash-order formats.
            return Detection(format: dayOrMonthFirst(texts, separator: "-"), ambiguous: false)
        }
        // Slash (or fallback): resolve day/month order + flag ambiguity.
        return disambiguateSlash(texts)
    }

    private static func isISO(_ s: String) -> Bool {
        let comps = s.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." })
        guard comps.count >= 3 else { return false }
        return comps[0].count == 4 && comps[0].allSatisfy(\.isNumber)
    }

    /// Pick day- vs month-first for a given separator based on evidence.
    private static func dayOrMonthFirst(_ texts: [String], separator: Character) -> ImportDateFormat {
        var firstOver12 = false
        var secondOver12 = false
        for s in texts {
            let parts = s.split(whereSeparator: { $0 == separator })
            guard parts.count >= 2,
                  let a = Int(parts[0].filter(\.isNumber)),
                  let b = Int(parts[1].filter(\.isNumber)) else { continue }
            if a > 12 { firstOver12 = true }
            if b > 12 { secondOver12 = true }
        }
        // If the second field exceeds 12 (and the first doesn't), it's month-first.
        // L1: the dot arm was a dead ternary (`.monthFirstSlash` on both sides) —
        // dot-separated month-first evidence now reports `.monthFirstDot`, mirroring
        // the day-first line below. The dash arm intentionally stays `.monthFirstSlash`
        // (dash dates reuse the slash-order formats — see the caller's comment).
        if secondOver12 && !firstOver12 {
            return separator == "." ? .monthFirstDot : .monthFirstSlash
        }
        return separator == "." ? .dayFirstDot : .dayFirstSlash
    }

    private static func disambiguateSlash(_ texts: [String]) -> Detection {
        var firstOver12 = false
        var secondOver12 = false
        for s in texts {
            let parts = s.split(whereSeparator: { $0 == "/" })
            guard parts.count >= 2,
                  let a = Int(parts[0].filter(\.isNumber)),
                  let b = Int(parts[1].filter(\.isNumber)) else { continue }
            if a > 12 { firstOver12 = true }
            if b > 12 { secondOver12 = true }
        }
        if firstOver12 && !secondOver12 { return Detection(format: .dayFirstSlash, ambiguous: false) }
        if secondOver12 && !firstOver12 { return Detection(format: .monthFirstSlash, ambiguous: false) }
        // Both ≤ 12 everywhere (or no evidence) → genuinely ambiguous. Default
        // day-first (Romanian reality) but flag it so the wizard asks.
        return Detection(format: .dayFirstSlash, ambiguous: true)
    }

    // MARK: - Parsing a single cell

    /// Parse one date cell with the chosen format. Tries the base pattern plus
    /// common time suffixes, and honors an xlsx serial date. A parsed value that
    /// lands at exactly midnight is normalized to 12:00 (rows lacking a time →
    /// noon, C2). Returns `nil` when nothing parses. Convenience overload that
    /// builds the formatters each call — fine for tests / one-offs; the bulk
    /// importer passes prebuilt formatters via the overload below.
    static func parse(cell: SheetCell, format: ImportDateFormat) -> Date? {
        parse(cell: cell, format: format, formatters: formatters(for: format))
    }

    /// The DateFormatters to try for a format, built ONCE and reused across every
    /// row (creating a `DateFormatter` per cell would make a thousands-row import
    /// crawl). Empty for `.excelSerial`.
    static func formatters(for format: ImportDateFormat) -> [DateFormatter] {
        guard let base = format.pattern else { return [] }
        return candidatePatterns(base: base).map(makeFormatter)
    }

    /// Core parse with prebuilt formatters.
    static func parse(cell: SheetCell, format: ImportDateFormat, formatters: [DateFormatter]) -> Date? {
        // Excel serial (xlsx) — already a real Date.
        if format == .excelSerial {
            if let serial = cell.serialDate { return normalizedNoon(serial) }
            // Fall through: a serial-typed column might still hold a text date.
        } else if let serial = cell.serialDate {
            // Any column whose cell resolved a serial date: trust it over text.
            return normalizedNoon(serial)
        }

        let text = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard format.pattern != nil else {
            // .excelSerial but no serialDate and non-empty text: try a numeric
            // serial written as text.
            if let n = Double(text) { return normalizedNoon(excelSerialToDate(n)) }
            return nil
        }

        for f in formatters {
            if let date = f.date(from: text) { return normalizedNoon(date) }
        }
        return nil
    }

    /// Base date pattern (which fixes the day/month ORDER) expanded across the
    /// three separators and common time suffixes, longest first so a value that
    /// carries a time keeps it. Separator tolerance means a column detected as dot
    /// still parses the odd slash/dash row.
    private static func candidatePatterns(base: String) -> [String] {
        let separators: [Character] = [".", "/", "-"]
        var patterns: [String] = []
        for sep in separators {
            let swapped = String(base.map { ($0 == "." || $0 == "/" || $0 == "-") ? sep : $0 })
            patterns.append("\(swapped) HH:mm:ss")
            patterns.append("\(swapped) HH:mm")
            patterns.append("\(swapped)'T'HH:mm:ss")
            patterns.append("\(swapped)'T'HH:mm")
            patterns.append(swapped)
        }
        return patterns
    }

    /// If the date sits at exactly 00:00:00 (no time component), move it to 12:00.
    private static func normalizedNoon(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        if (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 {
            return cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }
        return date
    }

    /// Excel serial → Date (OLE automation epoch 1899-12-30), for serials that
    /// arrive as text rather than as a styled numeric cell.
    private static func excelSerialToDate(_ serial: Double) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let epoch = cal.date(from: DateComponents(year: 1899, month: 12, day: 30)) ?? Date(timeIntervalSince1970: 0)
        let days = Int(serial.rounded(.down))
        let seconds = Int((serial - Double(days)) * 86400.0)
        let withDays = cal.date(byAdding: .day, value: days, to: epoch) ?? epoch
        return cal.date(byAdding: .second, value: seconds, to: withDays) ?? withDays
    }
}
