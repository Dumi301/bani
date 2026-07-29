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

    // MARK: - Digit-based numbers ("12", "12,50", "12.50")

    private static func digitNumberSpans(_ tokens: [Token]) -> [NumberSpan] {
        var spans: [NumberSpan] = []
        for (index, token) in tokens.enumerated() {
            if let value = digitValue(token.clean) {
                spans.append(NumberSpan(range: index..<(index + 1), value: value))
            }
        }
        return spans
    }

    private static func digitValue(_ clean: String) -> Decimal? {
        guard !clean.isEmpty else { return nil }
        guard clean.contains(where: { $0.isNumber }) else { return nil }
        guard clean.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) else { return nil }
        let normalized = clean.replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

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
    /// "o" (RO) / "a" / "an" (EN) count as 1 ONLY immediately before a hundred word
    /// (e.g. "o sută", "a hundred") — never as a standalone number, since these are
    /// common articles that otherwise appear constantly in ordinary speech.
    private static let articleOneWords: Set<String> = ["o", "a", "an"]
    private static let connectorWords: Set<String> = ["si", "and"]

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

    /// Greedy grammar: `[hundredPart] [connector] (tensPart [connector] onesPart | teenPart | onesPart)`.
    /// Handles "douăzeci"=20, "cinci sute"=500, "o sută cincizeci"=150, "a hundred fifty"=150.
    private static func parseSpelledNumber(_ tokens: [Token], at start: Int) -> (value: Int, consumed: Int)? {
        var index = start
        var total = 0
        var consumed = 0

        // Hundred part.
        if index + 1 < tokens.count,
           let onesValue = onesWords[tokens[index].norm],
           hundredWords.contains(tokens[index + 1].norm) {
            total += onesValue * 100
            index += 2
            consumed += 2
        } else if index + 1 < tokens.count,
                  articleOneWords.contains(tokens[index].norm),
                  hundredWords.contains(tokens[index + 1].norm) {
            total += 100
            index += 2
            consumed += 2
        } else if hundredWords.contains(tokens[index].norm) {
            total += 100
            index += 1
            consumed += 1
        }

        // Optional connector ("și"/"and") between hundred part and what follows.
        if consumed > 0, index < tokens.count, connectorWords.contains(tokens[index].norm),
           index + 1 < tokens.count,
           tensWords[tokens[index + 1].norm] != nil
               || teenWords[tokens[index + 1].norm] != nil
               || onesWords[tokens[index + 1].norm] != nil {
            index += 1
            consumed += 1
        }

        // Tens / teen / ones part.
        if index < tokens.count, let tensValue = tensWords[tokens[index].norm] {
            total += tensValue
            index += 1
            consumed += 1

            var lookahead = index
            if lookahead < tokens.count, connectorWords.contains(tokens[lookahead].norm),
               lookahead + 1 < tokens.count, onesWords[tokens[lookahead + 1].norm] != nil {
                lookahead += 1
            }
            if lookahead < tokens.count, let onesValue = onesWords[tokens[lookahead].norm] {
                total += onesValue
                consumed += (lookahead - index) + 1
                index = lookahead + 1
            }
        } else if index < tokens.count, let teenValue = teenWords[tokens[index].norm] {
            total += teenValue
            index += 1
            consumed += 1
        } else if index < tokens.count, let onesValue = onesWords[tokens[index].norm] {
            total += onesValue
            index += 1
            consumed += 1
        }

        guard consumed > 0 else { return nil }
        return (total, consumed)
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
