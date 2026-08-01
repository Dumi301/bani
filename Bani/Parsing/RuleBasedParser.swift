import Foundation

/// Deterministic, offline parser for spoken/typed Romanian + English cash-logging
/// utterances. Default parser everywhere; `FoundationModelsParser` falls back to
/// this on unavailability or error.
///
/// Pure value logic — no shared mutable state, `Sendable`, safe to call from
/// any isolation context.
///
/// AMOUNT SELECTION PRECEDENCE:
/// 1. The number token adjacent to a currency word ("de lei" / "lei" / "ron" /
///    "euro" / "eur" / "€").
/// 2. If no currency word is present, the LAST number token.
///
/// Digit forms are preferred over spelled forms only as a *parsing method*
/// (spelled RO/EN number words 1...999 are parsed only when the utterance
/// contains no digits at all) — it does not change selection precedence.
/// Never invents a number: if none can be found, `amount` is `nil`.
struct RuleBasedParser: TransactionParsing {

    init() {}

    func parse(_ text: String) async -> ParsedTransaction {
        Self.parseSync(text)
    }

    // MARK: - Pure parsing

    private struct Token {
        let raw: String   // original slice, diacritics/case preserved (for description rebuild)
        let clean: String // boundary punctuation trimmed, original case/diacritics
        let norm: String  // lowercased + diacritic-folded `clean` (for dictionary lookups)
    }

    private struct NumberSpan {
        let range: Range<Int>
        let value: Decimal
    }

    private struct CurrencyOccurrence {
        let phraseRange: Range<Int>
        let currency: Currency
    }

    static func parseSync(_ text: String) -> ParsedTransaction {
        let rawTokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rawTokens.isEmpty else {
            return ParsedTransaction(
                amount: nil,
                currency: .ron,
                descriptionText: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let tokens: [Token] = rawTokens.map { raw in
            let clean = cleaned(raw)
            return Token(raw: raw, clean: clean, norm: normalize(clean))
        }

        let hasDigits = text.contains(where: { $0.isNumber })
        let numberSpans: [NumberSpan] = hasDigits ? digitNumberSpans(tokens) : spelledNumberSpans(tokens)
        let occurrences = currencyOccurrences(in: tokens)

        var selectedSpan: NumberSpan?
        var currency: Currency = .ron

        if !occurrences.isEmpty {
            // Rule 1: number token adjacent to a currency word.
            var adjacentMatch: (span: NumberSpan, occurrence: CurrencyOccurrence)?
            for occurrence in occurrences {
                if let span = numberSpans.first(where: {
                    $0.range.upperBound == occurrence.phraseRange.lowerBound
                        || $0.range.lowerBound == occurrence.phraseRange.upperBound
                }) {
                    adjacentMatch = (span, occurrence)
                    break
                }
            }
            if let match = adjacentMatch {
                selectedSpan = match.span
                currency = match.occurrence.currency
            } else {
                // Currency word present but nothing touches it — best-effort fallback,
                // still never invents a number.
                selectedSpan = numberSpans.last
                currency = occurrences[0].currency
            }
        } else {
            // Rule 2: no currency word — last number token; currency defaults to RON.
            selectedSpan = numberSpans.last
            currency = .ron
        }

        // B4 guardrail: an amount above 100,000,000 is almost certainly a mishear
        // (a stray thousands/millions multiplier stacking up). Reject it — leave
        // `amount` nil so the card opens in edit mode — but KEEP the number token
        // in the description so the rejected value stays visible in the card and
        // the "Last voice session" forensics row (never silently saved).
        if let span = selectedSpan, span.value > amountGuardrailMax {
            selectedSpan = nil
        }

        var removedIndices = Set<Int>()
        if let span = selectedSpan {
            removedIndices.formUnion(span.range)
        }
        for occurrence in occurrences {
            removedIndices.formUnion(occurrence.phraseRange)
        }

        let remainderTokens = tokens.indices.compactMap { removedIndices.contains($0) ? nil : tokens[$0].raw }
        let descriptionText = remainderTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedTransaction(
            amount: selectedSpan?.value,
            currency: currency,
            descriptionText: descriptionText
        )
    }

    // MARK: - Token cleaning / normalization

    private static func cleaned(_ token: String) -> String {
        var s = Substring(token)
        func isBoundary(_ c: Character) -> Bool {
            !(c.isLetter || c.isNumber || c == "€")
        }
        while let first = s.first, isBoundary(first) { s.removeFirst() }
        while let last = s.last, isBoundary(last) { s.removeLast() }
        return String(s)
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "ro_RO")).lowercased()
    }

    // MARK: - Digit-based numbers ("12", "12,50", "12.50", "25.000", "25 000", "3 mii")

    /// `en_US_POSIX` so `Decimal(string:)` always reads "." as the decimal point,
    /// regardless of the device locale. Shared with the import lexer.
    private static let posix = AmountLexer.posix

    /// B4: reject parsed amounts strictly above this as almost-certain misheard
    /// noise (RON/EUR cash logging never legitimately exceeds 100 million).
    private static let amountGuardrailMax = Decimal(100_000_000)

    /// Builds digit-based number spans, each of which may cover MORE than one
    /// token: spaced thousands groups ("25 000" → 25000, B2) and a trailing
    /// multiplier word ("3 mii" → 3000, "2,5 milioane" → 2500000, B3) fold into a
    /// single span so the whole run leaves the description together.
    private static func digitNumberSpans(_ tokens: [Token]) -> [NumberSpan] {
        var spans: [NumberSpan] = []
        var index = 0
        while index < tokens.count {
            guard let base = AmountLexer.value(forDigitToken: tokens[index].clean) else {
                index += 1
                continue
            }
            var end = index + 1
            var value = base

            // B2: spaced digit grouping — absorb following pure-3-digit tokens
            // ("25 000", "1 234 567") into one number, but only when THIS token is
            // itself a plain integer (no separators, so "2,5 000" never merges).
            if AmountLexer.isPureDigits(tokens[index].clean) {
                var digits = tokens[index].clean
                while end < tokens.count,
                      AmountLexer.isPureDigits(tokens[end].clean),
                      tokens[end].clean.count == 3 {
                    digits += tokens[end].clean
                    end += 1
                }
                if end > index + 1 {
                    value = Decimal(string: digits, locale: posix) ?? value
                }
            }

            // B3: hybrid digit + multiplier word ("3 mii", "25 de mii",
            // "2,5 milioane", "1.5 million"). An optional connective "de" may sit
            // between the digits and the scale word; both join the span.
            if end < tokens.count, tokens[end].norm == deWord,
               end + 1 < tokens.count, let scale = multiplier(tokens[end + 1].norm) {
                value *= Decimal(scale)
                end += 2
            } else if end < tokens.count, let scale = multiplier(tokens[end].norm) {
                value *= Decimal(scale)
                end += 1
            }

            spans.append(NumberSpan(range: index..<end, value: value))
            index = end
        }
        return spans
    }

    // The separator-disambiguation core (`digitValue` / `isPureDigits`) now lives
    // in `AmountLexer` (shared with the Excel/CSV import); this file calls into it.

    // MARK: - Spelled numbers (RO + EN, 1...999) — parsed only when no digits are present

    private static let onesWords: [String: Int] = [
        "zero": 0,
        "unu": 1, "una": 1, "one": 1,
        "doi": 2, "doua": 2, "two": 2,
        "trei": 3, "three": 3,
        "patru": 4, "four": 4,
        "cinci": 5, "five": 5,
        "sase": 6, "six": 6,
        "sapte": 7, "seven": 7,
        "opt": 8, "eight": 8,
        "noua": 9, "nine": 9
    ]

    private static let teenWords: [String: Int] = [
        "zece": 10, "ten": 10,
        "unsprezece": 11, "eleven": 11,
        "doisprezece": 12, "twelve": 12,
        "treisprezece": 13, "thirteen": 13,
        "paisprezece": 14, "fourteen": 14,
        "cincisprezece": 15, "fifteen": 15,
        "saisprezece": 16, "sixteen": 16,
        "saptesprezece": 17, "seventeen": 17,
        "optsprezece": 18, "eighteen": 18,
        "nouasprezece": 19, "nineteen": 19
    ]

    private static let tensWords: [String: Int] = [
        "douazeci": 20, "twenty": 20,
        "treizeci": 30, "thirty": 30,
        "patruzeci": 40, "forty": 40,
        "cincizeci": 50, "fifty": 50,
        "saizeci": 60, "sixty": 60,
        "saptezeci": 70, "seventy": 70,
        "optzeci": 80, "eighty": 80,
        "nouazeci": 90, "ninety": 90
    ]

    /// "sută" / "sute" (RO) and "hundred" (EN) — the diacritic-folded, lowercased forms.
    private static let hundredWords: Set<String> = ["suta", "sute", "hundred"]
    /// "o" / "un" (RO) / "a" / "an" (EN) count as 1 ONLY immediately before a
    /// hundred or a scale word (e.g. "o sută", "o mie", "un milion", "a hundred",
    /// "a million") — never as a standalone number, since these are common
    /// articles that otherwise appear constantly in ordinary speech.
    private static let articleOneWords: Set<String> = ["o", "un", "a", "an"]
    private static let connectorWords: Set<String> = ["si", "and"]
    /// The Romanian connective "de" that links a number to a scale/currency word
    /// ("douăzeci de mii", "25 de lei").
    private static let deWord = "de"

    /// Scale multiplier words — thousands and millions, RO + EN (B3).
    private static let thousandWords: Set<String> = ["mie", "mii", "thousand", "thousands"]
    private static let millionWords: Set<String> = ["milion", "milioane", "million", "millions"]

    /// The multiplier a scale word applies, or `nil` if the token is not a scale word.
    private static func multiplier(_ norm: String) -> Int? {
        if thousandWords.contains(norm) { return 1_000 }
        if millionWords.contains(norm) { return 1_000_000 }
        return nil
    }

    private static func spelledNumberSpans(_ tokens: [Token]) -> [NumberSpan] {
        var spans: [NumberSpan] = []
        var index = 0
        while index < tokens.count {
            if let (value, consumed) = parseSpelledNumber(tokens, at: index) {
                spans.append(NumberSpan(range: index..<(index + consumed), value: Decimal(value)))
                index += consumed
            } else {
                index += 1
            }
        }
        return spans
    }

    /// Scale-aware left-to-right accumulator over spelled number words. Builds a
    /// running group value (ones/teens/tens/hundreds → 0…999) and flushes it into
    /// `total` whenever a scale word (mie/mii=×1000, milion/milioane=×1,000,000)
    /// is reached, so it handles both the small cases ("douăzeci"=20, "cinci
    /// sute"=500, "a hundred fifty"=150) and the large ones ("douăzeci și cinci de
    /// mii"=25000, "un milion două sute de mii"=1200000, "a million"=1000000).
    /// Connectives "și"/"and"/"de" are consumed only when a number/scale word
    /// follows, so a trailing "de lei" / "and …" is left for the currency/remainder.
    private static func parseSpelledNumber(_ tokens: [Token], at start: Int) -> (value: Int, consumed: Int)? {
        var index = start
        var total = 0        // accumulated value with scales applied
        var current = 0      // the in-progress group (0…999)
        var consumed = 0
        var sawNumberWord = false

        loop: while index < tokens.count {
            let norm = tokens[index].norm

            if let ones = onesWords[norm] {
                current += ones
            } else if let teen = teenWords[norm] {
                current += teen
            } else if let tens = tensWords[norm] {
                current += tens
            } else if hundredWords.contains(norm) {
                current = (current == 0 ? 1 : current) * 100
            } else if let scale = multiplier(norm) {
                total += (current == 0 ? 1 : current) * scale
                current = 0
            } else if articleOneWords.contains(norm),
                      index + 1 < tokens.count,
                      hundredWords.contains(tokens[index + 1].norm) || multiplier(tokens[index + 1].norm) != nil {
                // "o"/"un"/"a"/"an" == 1, only right before a hundred or scale word.
                current += 1
            } else if connectorWords.contains(norm) || norm == deWord {
                // Connective — consume ONLY when a number/scale word follows.
                guard index + 1 < tokens.count else { break loop }
                let next = tokens[index + 1].norm
                let numberFollows = onesWords[next] != nil || teenWords[next] != nil
                    || tensWords[next] != nil || hundredWords.contains(next)
                    || multiplier(next) != nil || articleOneWords.contains(next)
                if norm == deWord {
                    // "de" only bridges to a scale word ("de mii"); "de lei" breaks.
                    guard multiplier(next) != nil else { break loop }
                } else {
                    guard numberFollows else { break loop }
                }
                index += 1
                consumed += 1
                continue loop   // connective consumed; not itself a number word
            } else {
                break loop
            }

            index += 1
            consumed += 1
            sawNumberWord = true
        }

        guard sawNumberWord else { return nil }
        return (total + current, consumed)
    }

    // MARK: - Currency words

    private static let ronWords: Set<String> = ["lei", "ron"]
    private static let eurWords: Set<String> = ["euro", "eur"]

    private static func currencyOccurrences(in tokens: [Token]) -> [CurrencyOccurrence] {
        var occurrences: [CurrencyOccurrence] = []
        for (index, token) in tokens.enumerated() {
            let currency: Currency?
            if ronWords.contains(token.norm) {
                currency = .ron
            } else if eurWords.contains(token.norm) || token.clean == "€" {
                currency = .eur
            } else {
                currency = nil
            }
            guard let currency else { continue }

            var phraseStart = index
            if index > 0, tokens[index - 1].norm == "de" {
                phraseStart = index - 1
            }
            occurrences.append(CurrencyOccurrence(phraseRange: phraseStart..<(index + 1), currency: currency))
        }
        return occurrences
    }
}
