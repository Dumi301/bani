import Foundation

/// One amount found free-floating in document text, with its position + currency.
struct ScannedAmount: Equatable, Sendable {
    var value: Decimal
    var currency: Currency?
    /// Character offset of the match start (for "nearest keyword" selection).
    var location: Int
    /// Whether it was written in words (vs digits) — digits win a dedup tie.
    var fromWords: Bool
}

/// Finds monetary amounts in free-form document text — digits AND Romanian/English
/// number words — and de-duplicates the common "1.200 lei (una mie două sute)"
/// duplicate (E1). Built on `AmountLexer.value(forDigitToken:)` so the decimal /
/// thousands disambiguation is byte-identical to the voice + spreadsheet paths.
enum AmountScanner {

    static func scan(_ text: String) -> [ScannedAmount] {
        var found = digitAmounts(text) + wordAmounts(text)
        // Dedup by equal value: keep the digit occurrence over a word one, else the
        // earliest. Equal values within ~40 chars are treated as the same amount
        // restated in words.
        found.sort { $0.location < $1.location }
        var out: [ScannedAmount] = []
        for a in found {
            if let i = out.firstIndex(where: { $0.value == a.value && abs($0.location - a.location) < 80 }) {
                if out[i].fromWords && !a.fromWords {
                    out[i] = ScannedAmount(value: a.value, currency: a.currency ?? out[i].currency, location: out[i].location, fromWords: false)
                } else if out[i].currency == nil, let c = a.currency {
                    out[i].currency = c
                }
            } else {
                out.append(a)
            }
        }
        return out
    }

    /// The "primary" amount: the one nearest a value keyword (chirie/total/suma/
    /// pret/valoare/rent/amount/price), else the largest. `nil` if none.
    static func primary(_ text: String) -> ScannedAmount? {
        let amounts = scan(text)
        guard !amounts.isEmpty else { return nil }
        let folded = Categorizer.normalize(text)
        let keywords = ["chirie", "total", "suma", "pret", "valoare", "rent", "amount", "price", "onorariu", "comision"]
        var bestByKeyword: (ScannedAmount, Int)?
        for kw in keywords {
            var searchStart = folded.startIndex
            while let r = folded.range(of: kw, range: searchStart..<folded.endIndex) {
                let kwLoc = folded.distance(from: folded.startIndex, to: r.lowerBound)
                for a in amounts {
                    let dist = abs(a.location - kwLoc)
                    if dist < 60, bestByKeyword == nil || dist < bestByKeyword!.1 {
                        bestByKeyword = (a, dist)
                    }
                }
                searchStart = r.upperBound
            }
        }
        if let best = bestByKeyword { return best.0 }
        return amounts.max { $0.value < $1.value }
    }

    // MARK: - Digit amounts

    private static func digitAmounts(_ text: String) -> [ScannedAmount] {
        var out: [ScannedAmount] = []
        // A digit run possibly grouped with . , or spaces.
        let pattern = "\\d[\\d.,\\u00A0 ]*\\d|\\d"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let raw = ns.substring(with: m.range)
            let core = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
            guard let value = AmountLexer.value(forDigitToken: core), value > 0 else { continue }
            let currency = currencyNear(text: ns, around: m.range)
            out.append(ScannedAmount(value: value, currency: currency, location: m.range.location, fromWords: false))
        }
        return out
    }

    /// Detect a currency word/symbol within ~12 chars on either side of a match.
    private static func currencyNear(text ns: NSString, around range: NSRange) -> Currency? {
        let start = max(0, range.location - 12)
        let end = min(ns.length, range.location + range.length + 12)
        let window = Categorizer.normalize(ns.substring(with: NSRange(location: start, length: end - start)))
        if window.contains("eur") || window.contains("euro") || window.contains("€") { return .eur }
        if window.contains("lei") || window.contains("ron") { return .ron }
        return nil
    }

    // MARK: - Word amounts (RO + EN)

    private static func wordAmounts(_ text: String) -> [ScannedAmount] {
        let ns = text as NSString
        var out: [ScannedAmount] = []
        // Slide over token runs; try to parse each maximal run of number-words.
        let tokens = tokenize(text)
        var i = 0
        while i < tokens.count {
            if numberWord(tokens[i].word) {
                var j = i
                while j < tokens.count && (numberWord(tokens[j].word) || connector(tokens[j].word)) { j += 1 }
                let run = Array(tokens[i..<j])
                let words = run.map(\.word)
                if let value = RomanianNumberWords.parse(words) ?? EnglishNumberWords.parse(words), value > 0 {
                    let loc = run.first!.location
                    let currency = currencyNear(text: ns, around: NSRange(location: loc, length: 1))
                    out.append(ScannedAmount(value: value, currency: currency, location: loc, fromWords: true))
                }
                i = j
            } else { i += 1 }
        }
        return out
    }

    private struct Tok { var word: String; var location: Int }
    private static func tokenize(_ text: String) -> [Tok] {
        var out: [Tok] = []
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}]+") else { return [] }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(Tok(word: Categorizer.normalize(ns.substring(with: m.range)), location: m.range.location))
        }
        return out
    }

    private static func connector(_ w: String) -> Bool { ["si", "de", "and", "virgula"].contains(w) }
    private static func numberWord(_ w: String) -> Bool {
        RomanianNumberWords.isWord(w) || EnglishNumberWords.isWord(w)
    }
}

/// Romanian cardinal number-words → value (0–9,999,999). Tokens are pre-normalized
/// (diacritic-folded, lowercased). Classic accumulate-with-scale algorithm.
enum RomanianNumberWords {
    static let units: [String: Int] = ["zero": 0, "o": 1, "un": 1, "unu": 1, "una": 1, "doi": 2, "doua": 2,
        "trei": 3, "patru": 4, "cinci": 5, "sase": 6, "sapte": 7, "opt": 8, "noua": 9]
    static let teens: [String: Int] = ["zece": 10, "unsprezece": 11, "doisprezece": 12, "douasprezece": 12,
        "treisprezece": 13, "paisprezece": 14, "cincisprezece": 15, "saisprezece": 16,
        "saptesprezece": 17, "optsprezece": 18, "nouasprezece": 19]
    static let tens: [String: Int] = ["douazeci": 20, "treizeci": 30, "patruzeci": 40, "cincizeci": 50,
        "saizeci": 60, "saptezeci": 70, "optzeci": 80, "nouazeci": 90]

    static func isWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil
            || ["suta", "sute", "mie", "mii", "milion", "milioane"].contains(w)
    }

    static func parse(_ words: [String]) -> Decimal? {
        var total = 0, current = 0, any = false
        for w in words {
            if let u = units[w] { current += u; any = true }
            else if let t = teens[w] { current += t; any = true }
            else if let t = tens[w] { current += t; any = true }
            else if w == "suta" || w == "sute" { current = max(current, 1) * 100; any = true }
            else if w == "mie" || w == "mii" { total += max(current, 1) * 1000; current = 0; any = true }
            else if w == "milion" || w == "milioane" { total += max(current, 1) * 1_000_000; current = 0; any = true }
            // connectors ignored
        }
        guard any else { return nil }
        return Decimal(total + current)
    }
}

/// English cardinal number-words → value (0–9,999,999).
enum EnglishNumberWords {
    static let units: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    static func isWord(_ w: String) -> Bool {
        units[w] != nil || tens[w] != nil || ["hundred", "thousand", "million"].contains(w)
    }

    static func parse(_ words: [String]) -> Decimal? {
        var total = 0, current = 0, any = false
        for w in words {
            if let u = units[w] { current += u; any = true }
            else if let t = tens[w] { current += t; any = true }
            else if w == "hundred" { current = max(current, 1) * 100; any = true }
            else if w == "thousand" { total += max(current, 1) * 1000; current = 0; any = true }
            else if w == "million" { total += max(current, 1) * 1_000_000; current = 0; any = true }
        }
        guard any else { return nil }
        return Decimal(total + current)
    }
}
