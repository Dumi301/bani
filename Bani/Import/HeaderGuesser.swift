import Foundation

/// Auto-guesses a column→field mapping from the header row (C2). Header names are
/// diacritic-folded + lowercased (via `Categorizer.normalize`, the same folding
/// the parser/categorizer use) so "Dată" and "data" and "DATA" all match. Guesses
/// are only pre-selections — the wizard lets the user override every one.
enum HeaderGuesser {

    /// The Bani fields a header can be guessed for.
    enum Field: CaseIterable {
        case date, amount, description, category, currency, context
    }

    /// Normalized keyword sets (RO + EN, already diacritic-folded, all ≥4 chars so
    /// substring token matching stays safe). Documented in build-notes.md.
    static let keywords: [Field: [String]] = [
        .date:        ["data", "date", "ziua", "perioada"],
        .amount:      ["suma", "valoare", "amount", "total", "value", "pret", "cost", "cheltuiala", "debit"],
        .description: ["descriere", "detalii", "description", "denumire", "explicatie", "comentariu", "comment", "note", "detail", "beneficiar", "furnizor"],
        .category:    ["categorie", "category", "categ"],
        .currency:    ["moneda", "valuta", "currency", "deviza", "curr"],
        .context:     ["context", "type"],
    ]

    /// Build a best-effort mapping. Fields are assigned in priority order and a
    /// column is never reused, so a "Sumă" column claimed by amount can't also be
    /// taken by description.
    static func guess(headers: [String]) -> ImportFieldMapping {
        let normalized = headers.map { normalizeHeader($0) }
        var used = Set<Int>()
        var mapping = ImportFieldMapping()

        func assign(_ field: Field) -> Int? {
            guard let words = keywords[field] else { return nil }
            for (index, header) in normalized.enumerated() where !used.contains(index) {
                if matches(header: header, keywords: words) {
                    used.insert(index)
                    return index
                }
            }
            return nil
        }

        // Priority: the three required fields first, then the optional ones.
        mapping.dateColumn = assign(.date)
        mapping.amountColumn = assign(.amount)
        mapping.descriptionColumn = assign(.description)
        mapping.currencyColumn = assign(.currency)
        mapping.categoryColumn = assign(.category)
        mapping.contextColumn = assign(.context)
        return mapping
    }

    // MARK: - Matching

    static func normalizeHeader(_ header: String) -> String {
        Categorizer.normalize(header.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A keyword matches when a header token equals it or contains it (tokens are
    /// the header split on non-alphanumerics).
    static func matches(header: String, keywords: [String]) -> Bool {
        let tokens = Categorizer.tokenize(header)
        guard !tokens.isEmpty else { return false }
        for keyword in keywords {
            for token in tokens where token == keyword || token.contains(keyword) {
                return true
            }
        }
        return false
    }
}
