import Foundation

/// How the date column's values are read (C2). `.excelSerial` uses the resolved
/// `SheetCell.serialDate` (xlsx date-formatted numeric cells); the others parse
/// the cell text with a fixed `en_US_POSIX` formatter so parsing never depends on
/// the device locale.
enum ImportDateFormat: String, CaseIterable, Sendable, Identifiable {
    case dayFirstDot     // dd.MM.yyyy  (Romanian reality)
    case dayFirstSlash   // dd/MM/yyyy
    case iso             // yyyy-MM-dd
    case monthFirstSlash // MM/dd/yyyy
    /// L1 (v2.2 smalls): added to mirror `dayFirstDot`/`dayFirstSlash` — a
    /// dot-separated column with month-first evidence (second component > 12)
    /// now reports its OWN case instead of the slash one. Parsing itself was
    /// already separator-tolerant (`DateFieldParser.candidatePatterns` builds
    /// dot/slash/dash variants for whichever case is picked, so this is a
    /// display/detection-accuracy fix, not a parse-behavior change — see
    /// `DateFieldParser.dayOrMonthFirst`).
    case monthFirstDot   // MM.dd.yyyy
    case excelSerial     // numeric Excel serial → SheetCell.serialDate

    var id: String { rawValue }

    /// The base (date-only) `DateFormatter` pattern, or `nil` for serial dates.
    var pattern: String? {
        switch self {
        case .dayFirstDot:     "dd.MM.yyyy"
        case .dayFirstSlash:   "dd/MM/yyyy"
        case .iso:             "yyyy-MM-dd"
        case .monthFirstSlash: "MM/dd/yyyy"
        case .monthFirstDot:   "MM.dd.yyyy"
        case .excelSerial:     nil
        }
    }

    /// Short human sample for the picker ("31.12.2024", "2024-12-31", …).
    var sample: String {
        switch self {
        case .dayFirstDot:     "31.12.2024"
        case .dayFirstSlash:   "31/12/2024"
        case .iso:             "2024-12-31"
        case .monthFirstSlash: "12/31/2024"
        case .monthFirstDot:   "12.31.2024"
        case .excelSerial:     "45657"
        }
    }

    /// Localized picker label (ro + en).
    var label: String {
        switch self {
        case .dayFirstDot:     String(localized: "import.dateFmt.dayFirstDot")
        case .dayFirstSlash:   String(localized: "import.dateFmt.dayFirstSlash")
        case .iso:             String(localized: "import.dateFmt.iso")
        case .monthFirstSlash: String(localized: "import.dateFmt.monthFirst")
        case .monthFirstDot:   String(localized: "import.dateFmt.monthFirstDot")
        case .excelSerial:     String(localized: "import.dateFmt.excelSerial")
        }
    }
}

/// How negative amounts are handled for the whole file (C2) — shown ONLY when the
/// file actually contains negatives.
enum NegativesPolicy: String, CaseIterable, Sendable, Identifiable {
    case absolute   // import as positive expenses (abs)
    case skip       // skip rows with a negative amount
    var id: String { rawValue }

    /// Localized picker label (ro + en).
    var label: String {
        switch self {
        case .absolute: String(localized: "import.negatives.absolute")
        case .skip:     String(localized: "import.negatives.skip")
        }
    }
}

/// The complete column→field mapping the wizard assembles for one import (C2).
/// Column values are 0-based indices into the sheet's columns; `nil` = unmapped.
struct ImportFieldMapping: Equatable, Sendable {
    var dateColumn: Int?          // required
    var amountColumn: Int?        // required
    var descriptionColumn: Int?   // required
    var categoryColumn: Int?      // optional

    // Currency: a column OR a fixed choice (used when `currencyColumn == nil`).
    var currencyColumn: Int?
    var fixedCurrency: Currency = .ron

    // Context: a column OR a fixed choice (fixed is the default path, C2).
    var contextColumn: Int?
    var fixedContext: TransactionContext = .personal

    var dateFormat: ImportDateFormat = .dayFirstDot
    var negativesPolicy: NegativesPolicy = .absolute

    /// The three required fields are all mapped — the gate for leaving the mapping
    /// screen.
    var isComplete: Bool {
        dateColumn != nil && amountColumn != nil && descriptionColumn != nil
    }

    /// Whether a distinct column is used for currency / context / category.
    var usesCurrencyColumn: Bool { currencyColumn != nil }
    var usesContextColumn: Bool { contextColumn != nil }
    var usesCategoryColumn: Bool { categoryColumn != nil }
}
