import Foundation

/// Where an imported row's category comes from (resolved to a concrete
/// `CategoryRef` at execution time, since "create as custom" needs a live
/// `ModelContext` to mint the id).
enum ImportCategorySource: Equatable, Sendable {
    /// No category column — categorize by the description via the live rules.
    case byDescription
    /// A mapped category-column value — resolved through the user's per-value
    /// decisions / the matcher at execution. Empty string is never stored here.
    case columnValue(String)
    /// Explicitly uncategorized (mapped column, but this cell was blank).
    case uncategorized
}

/// A fully-validated row ready to become a `Transaction`. Amount is a positive
/// magnitude (negatives already resolved per policy). Category is deferred to
/// `categorySource`. Pure value type, `Sendable`.
struct ParsedImportRow: Equatable, Sendable {
    var date: Date
    var amount: Decimal
    var currency: Currency
    var descriptionText: String
    var context: TransactionContext
    var categorySource: ImportCategorySource
    var sourceRow: Int
    var fingerprint: String
    /// A1 — money direction. Defaults to `.expense` so the legacy generic-tabular
    /// wizard path is unchanged; the family parsers (D) set income/neutral.
    var direction: TransactionDirection = .expense
    /// A2/B2 — the extracted counterparty, when a family parser or document
    /// extractor found one. `nil` for the generic path.
    var counterparty: String? = nil
}

/// Why a row was skipped (surfaced with its row number in the summary, C5).
enum ImportSkipReason: String, Equatable, Sendable {
    case missingDate
    case unparseableDate
    case missingAmount
    case unparseableAmount
    case implausibleAmount
    case missingDescription
    case negativeSkipped

    var label: String {
        switch self {
        case .missingDate:        String(localized: "import.skip.missingDate")
        case .unparseableDate:     String(localized: "import.skip.unparseableDate")
        case .missingAmount:       String(localized: "import.skip.missingAmount")
        case .unparseableAmount:   String(localized: "import.skip.unparseableAmount")
        case .implausibleAmount:   String(localized: "import.skip.implausibleAmount")
        case .missingDescription:  String(localized: "import.skip.missingDescription")
        case .negativeSkipped:     String(localized: "import.skip.negativeSkipped")
        }
    }
}

/// A skipped row with the raw values that made it un-importable.
struct SkippedImportRow: Equatable, Sendable {
    var sourceRow: Int
    var reason: ImportSkipReason
    var rawDate: String
    var rawAmount: String
    var rawDescription: String
}

/// The outcome of parsing a whole sheet under a mapping.
struct ImportParseResult: Sendable {
    var rows: [ParsedImportRow]
    var skipped: [SkippedImportRow]
    /// Any negative amount was seen (regardless of policy) — gates showing the
    /// negatives choice (C2, shown ONLY if negatives exist).
    var negativesFound: Bool
    /// Distinct non-empty category-column values, first-appearance order (only
    /// populated when a category column is mapped) — drives the match screen.
    var distinctCategoryValues: [String]
}

/// Turns a `TabularSheet` + `ImportFieldMapping` into validated rows and skip
/// records. Pure and `Sendable` — no `ModelContext`, no I/O — so the whole
/// validation is unit-testable and can run off the main actor.
enum ImportRowParser {

    static func parse(sheet: TabularSheet, mapping: ImportFieldMapping) -> ImportParseResult {
        var rows: [ParsedImportRow] = []
        var skipped: [SkippedImportRow] = []
        var negativesFound = false
        var distinctCategory: [String] = []
        var seenCategory = Set<String>()

        // Build the date formatters ONCE for the whole sheet (per-row creation
        // would make a thousands-row import crawl).
        let dateFormatters = DateFieldParser.formatters(for: mapping.dateFormat)

        for row in sheet.rows {
            let rawDate = mapping.dateColumn.map { row.text(at: $0) } ?? ""
            let rawAmount = mapping.amountColumn.map { row.text(at: $0) } ?? ""
            let rawDesc = mapping.descriptionColumn.map { row.text(at: $0) } ?? ""

            func skip(_ reason: ImportSkipReason) {
                skipped.append(SkippedImportRow(
                    sourceRow: row.sourceRow, reason: reason,
                    rawDate: rawDate, rawAmount: rawAmount, rawDescription: rawDesc
                ))
            }

            // Date (required).
            guard let dateColumn = mapping.dateColumn, let dateCell = row.cell(at: dateColumn),
                  !dateCell.isEmpty else { skip(.missingDate); continue }
            guard let date = DateFieldParser.parse(cell: dateCell, format: mapping.dateFormat, formatters: dateFormatters) else {
                skip(.unparseableDate); continue
            }

            // Amount (required). PREFER a resolved xlsx numeric value (float-dust
            // safe) over re-lexing the raw cell string; fall back to the string
            // lexer for text/CSV cells.
            let trimmedAmount = rawAmount.trimmingCharacters(in: .whitespacesAndNewlines)
            let amountNumeric = mapping.amountColumn.flatMap { row.cell(at: $0) }?.numericValue
            let classified: AmountLexer.CellAmount
            if let amountNumeric {
                classified = AmountLexer.classify(numeric: amountNumeric)
            } else {
                guard !trimmedAmount.isEmpty else { skip(.missingAmount); continue }
                classified = AmountLexer.classifyCell(trimmedAmount)
            }
            let parsedAmount: AmountLexer.Amount
            switch classified {
            case .value(let a):
                parsedAmount = a
            case .implausible:
                // Never silently commit; never silently drop — surface the reason.
                skip(.implausibleAmount); continue
            case .none:
                skip(trimmedAmount.isEmpty ? .missingAmount : .unparseableAmount); continue
            }
            if parsedAmount.isNegative { negativesFound = true }
            if parsedAmount.isNegative && mapping.negativesPolicy == .skip {
                skip(.negativeSkipped); continue
            }
            let amount = parsedAmount.magnitude   // abs — always positive

            // Description (required).
            let description = rawDesc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { skip(.missingDescription); continue }

            // Currency: column or fixed.
            let currency: Currency = {
                guard let col = mapping.currencyColumn else { return mapping.fixedCurrency }
                return parseCurrency(row.text(at: col)) ?? mapping.fixedCurrency
            }()

            // Context: column or fixed.
            let context: TransactionContext = {
                guard let col = mapping.contextColumn else { return mapping.fixedContext }
                return parseContext(row.text(at: col)) ?? mapping.fixedContext
            }()

            // Category source (resolved to a ref at execution).
            let categorySource: ImportCategorySource
            if let col = mapping.categoryColumn {
                let value = row.text(at: col).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    categorySource = .uncategorized
                } else {
                    categorySource = .columnValue(value)
                    let key = Categorizer.normalize(value)
                    if !seenCategory.contains(key) { seenCategory.insert(key); distinctCategory.append(value) }
                }
            } else {
                categorySource = .byDescription
            }

            let fingerprint = ImportFingerprint.fingerprint(date: date, amount: amount, description: description)
            rows.append(ParsedImportRow(
                date: date, amount: amount, currency: currency,
                descriptionText: description, context: context,
                categorySource: categorySource, sourceRow: row.sourceRow, fingerprint: fingerprint
            ))
        }

        return ImportParseResult(
            rows: rows, skipped: skipped,
            negativesFound: negativesFound, distinctCategoryValues: distinctCategory
        )
    }

    // MARK: - Value parsing

    static func parseCurrency(_ raw: String) -> Currency? {
        let n = Categorizer.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if n.isEmpty { return nil }
        if ["ron", "lei", "leu", "rol"].contains(n) || n.contains("ron") || n.contains("lei") { return .ron }
        if ["eur", "euro"].contains(n) || n.contains("eur") || raw.contains("€") { return .eur }
        return nil
    }

    static func parseContext(_ raw: String) -> TransactionContext? {
        let n = Categorizer.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if n.isEmpty { return nil }
        let work = ["work", "munca", "serviciu", "business", "job", "birou", "firma", "companie"]
        let personal = ["personal", "persoana", "acasa", "home", "privat", "private", "familie"]
        if work.contains(where: { n == $0 || n.contains($0) }) { return .work }
        if personal.contains(where: { n == $0 || n.contains($0) }) { return .personal }
        return nil
    }
}
