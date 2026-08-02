import Foundation

/// The always-available document extractor (E1): a regex cascade over the
/// document's text — amounts (digits + number words, via `AmountScanner`), RO/EN
/// dates (numeric + month-name, incl. "începând cu …"), party names near
/// role keywords, and doc-type keywords. Pure + `Sendable` (no I/O, no model), so
/// the whole extraction is unit-tested directly (`extractSync`).
struct HeuristicExtractor: DocumentUnderstanding {
    var isAvailable: Bool { true }

    func understand(text: String, fileName: String, importDate: Date) async -> ExtractedTransaction {
        extractSync(text: text, fileName: fileName, importDate: importDate)
    }

    /// Synchronous core (the test seam).
    func extractSync(text: String, fileName: String, importDate: Date) -> ExtractedTransaction {
        let docType = detectDocType(text)
        let language = detectLanguage(text)

        let primary = AmountScanner.primary(text)
        let amount = primary?.value
        let currency = primary?.currency ?? .ron
        let amountConfidence: Double = amount == nil ? 0 : (primary!.fromWords ? 0.6 : 0.82)

        let foundDate = DocumentDates.firstDate(in: text)
        let date = foundDate ?? importDate
        let dateWasFallback = foundDate == nil

        let party = counterparty(in: text)
        let direction = guessDirection(docType: docType, text: text)

        let description = descriptionText(docType: docType, party: party, fileName: fileName, language: language)
        let summary = buildSummary(docType: docType, party: party, amount: amount, currency: currency, date: foundDate, language: language)

        return ExtractedTransaction(
            amount: amount, currency: currency, date: date, dateWasFallback: dateWasFallback,
            counterparty: party, descriptionText: description, direction: direction,
            docType: docType, summary: summary,
            amountConfidence: amountConfidence,
            dateConfidence: foundDate == nil ? 0 : 0.7,
            counterpartyConfidence: party == nil ? 0 : 0.6
        )
    }

    // MARK: - Doc type

    func detectDocType(_ text: String) -> DocType {
        let n = Categorizer.normalize(text)
        if n.contains("contract") { return .contract }
        if n.contains("factura") || n.contains("invoice") { return .invoice }
        if n.contains("chitanta") || n.contains("bon fiscal") || n.contains("receipt") || n.contains("chitanță") { return .receipt }
        return .unknown
    }

    // MARK: - Counterparty

    /// Party-role keywords: the name usually follows on the same line, often after
    /// ":" (chiriaș/locatar tenant, locator landlord, prestator provider,
    /// beneficiar/client customer, vânzător/cumpărător).
    static let partyKeywords = ["chirias", "locatar", "locator", "prestator", "beneficiar", "client", "vanzator", "cumparator", "furnizor"]

    func counterparty(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let folded = Categorizer.normalize(line)
            for kw in Self.partyKeywords where folded.contains(kw) {
                // Take the text after the last ":" on the line, else after the keyword.
                if let colon = line.range(of: ":", options: .backwards) {
                    let name = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cleaned = cleanName(name) { return cleaned }
                }
                if let r = folded.range(of: kw) {
                    let offset = folded.distance(from: folded.startIndex, to: r.upperBound)
                    let idx = line.index(line.startIndex, offsetBy: offset, limitedBy: line.endIndex) ?? line.endIndex
                    let after = String(line[idx...])
                    if let cleaned = cleanName(after.trimmingCharacters(in: CharacterSet(charactersIn: " :,-"))) { return cleaned }
                }
            }
        }
        // Fallback: a run of ≥2 Capitalized words (a proper name).
        return capitalizedName(in: text)
    }

    /// Keep a plausible name: up to the first 4 words, letters/spaces/hyphens only.
    private func cleanName(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0 == " " }).prefix(4).map(String.init)
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = name.filter { $0.isLetter }
        guard letters.count >= 3, name.count <= 60 else { return nil }
        return name
    }

    private func capitalizedName(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b([A-ZĂÂÎȘȚ][\\p{L}]+(?:\\s+[A-ZĂÂÎȘȚ][\\p{L}]+){1,2})\\b") else { return nil }
        let ns = text as NSString
        // Skip an all-caps header line by preferring a match that isn't the whole line.
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
            return ns.substring(with: m.range(at: 1))
        }
        return nil
    }

    // MARK: - Direction

    func guessDirection(docType: DocType, text: String) -> TransactionDirection {
        let n = Categorizer.normalize(text)
        // Rent received / incoming → income; otherwise a document is spending.
        if n.contains("chirie") && (n.contains("incaseaza") || n.contains("primeste") || n.contains("chirias")) {
            return .income
        }
        return .expense
    }

    // MARK: - Description + summary

    private func descriptionText(docType: DocType, party: String?, fileName: String, language: Language) -> String {
        let base = docType == .unknown
            ? (fileName as NSString).deletingPathExtension
            : docType.label
        if let party { return "\(base) — \(party)" }
        return base
    }

    private func buildSummary(docType: DocType, party: String?, amount: Decimal?, currency: Currency, date: Date?, language: Language) -> String {
        let amountStr = amount.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) \(currency.displayCode)" }
        switch language {
        case .romanian:
            var s = "Document de tip \(docType.label.lowercased())."
            if let party { s += " Parte identificată: \(party)." }
            if let amountStr { s += " Sumă: \(amountStr)." }
            return s
        case .english:
            var s = "A \(docType.label.lowercased()) document."
            if let party { s += " Party: \(party)." }
            if let amountStr { s += " Amount: \(amountStr)." }
            return s
        }
    }

    enum Language { case romanian, english }
    private func detectLanguage(_ text: String) -> Language {
        let lower = text.lowercased()
        let roMarkers = ["ă", "â", "î", "ș", "ț", " și ", "chirie", "contract de", "factura", "lei"]
        let hits = roMarkers.filter { lower.contains($0) }.count
        return hits >= 2 ? .romanian : .english
    }
}

/// RO/EN date scanning for documents: numeric (dd.MM.yyyy, dd/MM/yyyy, ISO) and
/// month-name ("1 ianuarie 2021", "January 5, 2021"), including the "începând cu"
/// lead-in common in Romanian contracts. Returns the FIRST plausible date.
enum DocumentDates {
    static let roMonths: [String: Int] = ["ianuarie": 1, "februarie": 2, "martie": 3, "aprilie": 4,
        "mai": 5, "iunie": 6, "iulie": 7, "august": 8, "septembrie": 9, "octombrie": 10,
        "noiembrie": 11, "decembrie": 12]
    static let enMonths: [String: Int] = ["january": 1, "february": 2, "march": 3, "april": 4,
        "may": 5, "june": 6, "july": 7, "august": 8, "september": 9, "october": 10,
        "november": 11, "december": 12]

    static func firstDate(in text: String) -> Date? {
        if let d = monthNameDate(text) { return d }
        return numericDate(text)
    }

    private static func numericDate(_ text: String) -> Date? {
        let ns = text as NSString
        // dd[sep]mm[sep]yyyy  OR  yyyy-mm-dd
        let patterns = ["\\b(\\d{1,2})[./-](\\d{1,2})[./-](\\d{4})\\b", "\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b"]
        for (i, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let a = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let b = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let c = Int(ns.substring(with: m.range(at: 3))) ?? 0
                let (day, month, year) = i == 0 ? (a, b, c) : (c, b, a)
                if let d = makeDate(day: day, month: month, year: year) { return d }
            }
        }
        return nil
    }

    private static func monthNameDate(_ text: String) -> Date? {
        let ns = text as NSString
        // "1 ianuarie 2021" / "5 January 2021"
        if let re = try? NSRegularExpression(pattern: "\\b(\\d{1,2})\\s+([\\p{L}]+)\\s+(\\d{4})\\b") {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let day = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let monthWord = Categorizer.normalize(ns.substring(with: m.range(at: 2)))
                let year = Int(ns.substring(with: m.range(at: 3))) ?? 0
                if let month = roMonths[monthWord] ?? enMonths[monthWord], let d = makeDate(day: day, month: month, year: year) {
                    return d
                }
            }
        }
        // "January 5, 2021"
        if let re = try? NSRegularExpression(pattern: "\\b([\\p{L}]+)\\s+(\\d{1,2}),?\\s+(\\d{4})\\b") {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let monthWord = Categorizer.normalize(ns.substring(with: m.range(at: 1)))
                let day = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let year = Int(ns.substring(with: m.range(at: 3))) ?? 0
                if let month = roMonths[monthWord] ?? enMonths[monthWord], let d = makeDate(day: day, month: month, year: year) {
                    return d
                }
            }
        }
        return nil
    }

    private static func makeDate(day: Int, month: Int, year: Int) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month), (1900...2100).contains(year) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}
