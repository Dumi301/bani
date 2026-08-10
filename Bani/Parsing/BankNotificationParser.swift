import Foundation

/// Part B — a profile-based extractor for bank-notification phrasing (physical
/// card / transfers / any bank), applied to the text a share-sheet capture
/// yielded (OCR of a screenshot, or shared plain text). PURE value logic,
/// `Sendable`, no SwiftData / no model code — unit-tested against synthetic
/// Raiffeisen-shaped RO fixtures plus generic RO/EN patterns.
///
/// Amounts go through `AmountLexer.classifyCell`, inheriting the float-dust fixes
/// + the plausibility cap. Unparseable → `amount == nil` → the caller opens an
/// edit-mode card with the OCR text visible (the silent-card-bail contract).
struct BankNotificationParse: Equatable, Sendable {
    var amount: Decimal?
    var currency: Currency
    var merchant: String?
    var direction: TransactionDirection

    static let empty = BankNotificationParse(amount: nil, currency: .ron, merchant: nil, direction: .expense)
}

enum BankNotificationParser {

    /// Incoming markers → `.income`. Folded (diacritic-insensitive) so "încasare"
    /// matches "incasare".
    static let incomeMarkers: [String] = [
        "transfer primit", "ai primit", "primit", "incasare", "incasat",
        "received", "credited", "incoming", "you received",
    ]

    /// Merchant lead-ins ("… la MEGA IMAGE", "… at TESCO"); counterparty lead-ins
    /// for an incoming transfer ("… de la ION", "… from JOHN").
    static let merchantLeads: [String] = [" la ", " at "]
    static let counterpartyLeads: [String] = [" de la ", " from "]

    /// Phrases that terminate a merchant/counterparty run (card tail, dates).
    static let stopPhrases: [String] = ["cu cardul", "cu card", "with card", " card", " pe data", " la data", " on "]

    static func parse(_ raw: String) -> BankNotificationParse {
        let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }

        let folded = Categorizer.normalize(text)   // fold + lowercase
        let direction: TransactionDirection = incomeMarkers.contains(where: { folded.contains($0) }) ? .income : .expense
        let (amount, currency) = extractAmountAndCurrency(text)
        let merchant = extractParty(from: text, incoming: direction == .income)
        return BankNotificationParse(amount: amount, currency: currency, merchant: merchant, direction: direction)
    }

    // MARK: - Amount + currency

    /// A number token: digits with `.`/`,`/whitespace grouping. Resolved by
    /// `AmountLexer.classifyCell`, so RO grouping ("1.234,56"), float-dust and the
    /// plausibility cap are all inherited.
    private static let numberPattern = "[0-9][0-9.,\\s]*[0-9]|[0-9]"
    private static let currencyPattern = "(RON|LEI|EUR|€)"

    static func extractAmountAndCurrency(_ text: String) -> (Decimal?, Currency) {
        let ns = text as NSString
        // number then currency: "45,00 RON".
        if let hit = firstMatch(in: text, pattern: "(\(numberPattern))\\s*\(currencyPattern)", numberGroup: 1, currencyGroup: 2, ns: ns) {
            return hit
        }
        // currency then number: "RON 45,00" / "€12.5".
        if let hit = firstMatch(in: text, pattern: "\(currencyPattern)\\s*(\(numberPattern))", numberGroup: 2, currencyGroup: 1, ns: ns) {
            return hit
        }
        // A bare number with no currency → default RON if it parses plausibly.
        if let re = try? NSRegularExpression(pattern: numberPattern),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           case .value(let a) = AmountLexer.classifyCell(ns.substring(with: m.range)) {
            return (a.magnitude, .ron)
        }
        return (nil, .ron)
    }

    private static func firstMatch(in text: String, pattern: String, numberGroup: Int, currencyGroup: Int, ns: NSString) -> (Decimal, Currency)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              case .value(let a) = AmountLexer.classifyCell(ns.substring(with: m.range(at: numberGroup)))
        else { return nil }
        let code = ns.substring(with: m.range(at: currencyGroup)).uppercased()
        let currency: Currency = (code == "EUR" || code == "€") ? .eur : .ron
        return (a.magnitude, currency)
    }

    // MARK: - Merchant / counterparty

    /// The merchant after "la/at", or the counterparty after "de la/from" for an
    /// incoming transfer, cut at the first stop phrase. Case-insensitive ranges are
    /// found in the ORIGINAL text (no separate lowercase copy) so indices never
    /// drift; the original casing is preserved (the name is shown verbatim).
    static func extractParty(from text: String, incoming: Bool) -> String? {
        let leads = incoming ? counterpartyLeads : merchantLeads
        for lead in leads {
            guard let leadRange = text.range(of: lead, options: [.caseInsensitive]) else { continue }
            let afterLead = leadRange.upperBound
            var end = text.endIndex
            for stop in stopPhrases {
                if let sr = text.range(of: stop, options: [.caseInsensitive], range: afterLead..<text.endIndex),
                   sr.lowerBound < end {
                    end = sr.lowerBound
                }
            }
            let candidate = String(text[afterLead..<end])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,-–—:\n"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
        }
        return nil
    }
}
