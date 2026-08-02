import Foundation

/// The client-corpus families with hardcoded parsers (D2 fast path).
enum ImportFamily: String, Sendable, Equatable {
    case a  // Investment Tracker (raw log)
    case b  // Raiffeisen statement (raw log)
    case c  // Centralizator (finished report ledger)
    case d  // Cheltuieli lunare (monthly detail)
}

/// Why a recognized sheet is skipped (surfaced as a plain-language report note,
/// never a raw error — F).
enum SheetSkipReason: String, Sendable, Equatable {
    case pivotSummary       // Family C `Sheet4` pivot
    case runningBalance     // Family C `Sheet1` cash ledger
    case budgetMatrix       // Family D yearly matrix / budget-variance
    case nonTransaction     // Family E (equipment BOM / spec sheets)
    case empty              // no rows

    var noteKey: String {
        switch self {
        case .pivotSummary:   "import.note.pivotSummary"
        case .runningBalance: "import.note.runningBalance"
        case .budgetMatrix:   "import.note.budgetMatrix"
        case .nonTransaction: "import.note.nonTransaction"
        case .empty:          "import.note.emptySheet"
        }
    }
}

/// How one sheet will be handled.
enum SheetRole: Equatable, Sendable {
    /// A recognized family transaction sheet → its hardcoded parser, `headerRow`
    /// (0-based) detected by scanning the preamble [bug #2].
    case transactions(ImportFamily, headerRow: Int)
    /// A recognized non-transaction sheet (pivot/matrix/BOM) → skipped with a note.
    case skipped(SheetSkipReason)
    /// Unknown tabular → the generic auto-map path (uncertainties → report).
    case generic
}

/// Per-sheet classification via the spec's detection signatures. Everything is
/// diacritic/space-folded through `Categorizer.normalize` so casing and accents
/// never matter. Pure + `Sendable`.
enum FamilyDetection {

    static let scanDepth = 20

    /// Classify one raw sheet.
    static func classify(_ sheet: RawSheet) -> SheetRole {
        let window = sheet.headerScanWindow(scanDepth)          // folded cells per row
        guard !sheet.rows.isEmpty, window.contains(where: { !$0.allSatisfy(\.isEmpty) }) else {
            return .skipped(.empty)
        }
        let joined = window.map { $0.joined(separator: " ") }   // one folded string per row

        // Family A — ≥3 of the investment-tracker header tokens in one row.
        if let h = firstRow(joined, where: { s in
            let sig = ["investitii", "cheltuieli", "curs bnr", "pret euro", "observatii"]
            return sig.filter { s.contains($0) }.count >= 3
        }) { return .transactions(.a, headerRow: h) }
        // Family A person-ledger variant.
        if let h = firstRow(joined, where: { s in
            let sig = ["suma adusa", "curs bnr", "euro", "observatii"]
            return sig.filter { s.contains($0) }.count >= 3
        }) { return .transactions(.a, headerRow: h) }

        // Family B — the transaction header carries BOTH debit + credit + descriere.
        if let h = firstRow(joined, where: { $0.contains("suma debit") && $0.contains("suma credit") && $0.contains("descrierea") }) {
            return .transactions(.b, headerRow: h)
        }

        // Family C ledger — IBAN + MONEDA + CATEGORIE + the valuta split.
        if let h = firstRow(joined, where: { $0.contains("iban") && $0.contains("moneda") && $0.contains("categorie") && $0.contains("debit valuta") }) {
            return .transactions(.c, headerRow: h)
        }
        // Family C pivot summary → skip.
        if joined.contains(where: { $0.contains("row labels") || $0.contains("count of debit") || $0.contains("count of credit") }) {
            return .skipped(.pivotSummary)
        }
        // Family C running-balance ledger → skip.
        if joined.contains(where: { $0.contains("incasare") && $0.contains("plata") && $0.contains("sod") }) {
            return .skipped(.runningBalance)
        }

        // Family D monthly DETAIL — DATA + Observatii + at least one known bucket col.
        if let h = firstRow(joined, where: { s in
            s.contains("data") && s.contains("observatii")
            && ["utilitati", "combustibil", "mancare", "necesare", "diverse"].contains(where: s.contains)
        }) { return .transactions(.d, headerRow: h) }
        // Family D yearly matrix / budget variance → skip.
        if joined.contains(where: { s in
            s.contains("data") && s.contains("total")
            && ["utilitati", "combustibil", "mancare"].contains(where: s.contains)
        }), sheet.rows.contains(where: { monthNameLead($0) }) {
            return .skipped(.budgetMatrix)
        }

        // Family E — equipment BOM or key/value spec sheet, no per-row date column.
        if joined.contains(where: { ($0.contains("denumire") && $0.contains("bucati")) || ($0.contains("categorie") && $0.contains("specificatii")) }) {
            return .skipped(.nonTransaction)
        }

        return .generic
    }

    /// First (0-based) row index whose folded joined string satisfies `test`.
    private static func firstRow(_ joined: [String], where test: (String) -> Bool) -> Int? {
        joined.firstIndex(where: test)
    }

    /// Whether a row's first cell is a Romanian month name (matrix rows).
    private static func monthNameLead(_ row: SheetRow) -> Bool {
        let months: Set<String> = ["ianuarie", "februarie", "martie", "aprilie", "mai", "iunie",
                                    "iulie", "august", "septembrie", "octombrie", "noiembrie", "decembrie"]
        return months.contains(Categorizer.normalize(row.text(at: 0)))
    }
}
