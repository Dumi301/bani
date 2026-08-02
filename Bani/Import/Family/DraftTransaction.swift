import Foundation

/// The category a family parser / document extractor assigns to a draft row.
/// Resolved to a concrete `CategoryRef` at commit time (`.seededCustom` needs the
/// live custom-category id `PresetSeeding` mints). Pure + `Sendable` so the
/// fixture oracle asserts categories with NO `ModelContext`.
enum DraftCategory: Equatable, Sendable {
    /// A pre-seeded real-estate/finance custom (spec §4.2).
    case seededCustom(SeededCustomCategory)
    /// A built-in preset (fuel, groceries, …).
    case preset(TransactionCategory)
    /// No explicit signal — categorize by the description via the live rules.
    case byDescription
    /// Deliberately uncategorized.
    case uncategorized
}

/// One extracted transaction from ANY source (family parser, generic tabular row,
/// or a document extractor) BEFORE it is committed. Amount is a positive
/// magnitude; the sign lives in `direction` (A1). Pure value type, `Sendable`, so
/// the whole pipeline is unit-testable with no SwiftData / no I/O.
struct DraftTransaction: Equatable, Sendable, Identifiable {
    var id = UUID()
    var date: Date
    /// E1 — the date fell back to the import date because none was found in the
    /// document (flagged in the report so the user can fix it).
    var dateWasFallback: Bool = false
    var amount: Decimal
    var currency: Currency
    var direction: TransactionDirection
    var descriptionText: String
    var counterparty: String?
    var context: TransactionContext
    var category: DraftCategory
    /// 1-based source row (tabular) / 0 (document).
    var sourceRow: Int
    /// Cross-batch dedup key (`ImportFingerprint`).
    var fingerprint: String
    /// E1 — per-field confidence 0…1 for a document draft (nil for tabular rows).
    var confidence: Double?
    /// E1 — 2–3 sentence plain-language summary for a document draft.
    var docSummary: String?

    init(
        id: UUID = UUID(),
        date: Date,
        dateWasFallback: Bool = false,
        amount: Decimal,
        currency: Currency,
        direction: TransactionDirection,
        descriptionText: String,
        counterparty: String? = nil,
        context: TransactionContext,
        category: DraftCategory,
        sourceRow: Int,
        confidence: Double? = nil,
        docSummary: String? = nil
    ) {
        self.id = id
        self.date = date
        self.dateWasFallback = dateWasFallback
        self.amount = amount
        self.currency = currency
        self.direction = direction
        self.descriptionText = descriptionText
        self.counterparty = counterparty
        self.context = context
        self.category = category
        self.sourceRow = sourceRow
        self.fingerprint = ImportFingerprint.fingerprint(date: date, amount: amount, description: descriptionText)
        self.confidence = confidence
        self.docSummary = docSummary
    }
}

/// Day-first (Romanian) multi-encoding date parsing for the family parsers —
/// fixes the comma separator [bug #3] and honours real Excel serial dates.
/// Blank-date forward-fill is the PARSER LOOP's job (carry the last non-nil).
enum FamilyDates {

    /// Parse one cell, or `nil` if blank/unparseable. Supports: resolved xlsx
    /// serial dates; `dd.MM.yyyy`; `dd,MM,yyyy` (comma, Family A's 20%);
    /// `dd/MM/yyyy`; `dd-MM-yyyy`; and ISO `yyyy-MM-dd`.
    static func parse(_ cell: SheetCell) -> Date? {
        if let serial = cell.serialDate { return noon(serial) }
        let t = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // ISO first (4-digit lead).
        let isoParts = t.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." || $0 == "," })
        if isoParts.count >= 3, isoParts[0].count == 4, isoParts[0].allSatisfy(\.isNumber) {
            if let d = formatter("yyyy-MM-dd").date(from: normalized(t, to: "-")) { return noon(d) }
        }
        // Day-first with any of . , / - as separator → normalize to "." then parse.
        let dotForm = normalized(t, to: ".")
        for pattern in ["dd.MM.yyyy", "d.M.yyyy", "dd.MM.yy", "d.M.yy"] {
            if let d = formatter(pattern).date(from: dotForm) { return noon(d) }
        }
        // A bare numeric Excel serial written as text (defensive — when the style
        // pass didn't resolve a date-formatted numeric cell, so `serialDate` was
        // nil but the cell still holds a serial like "44208").
        if t.allSatisfy(\.isNumber), let n = Double(t), n >= 20000, n <= 80000 {
            return noon(excelSerialToDate(n))
        }
        return nil
    }

    /// Excel serial → Date (OLE epoch 1899-12-30).
    private static func excelSerialToDate(_ serial: Double) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let epoch = cal.date(from: DateComponents(year: 1899, month: 12, day: 30)) ?? Date(timeIntervalSince1970: 0)
        return cal.date(byAdding: .day, value: Int(serial.rounded(.down)), to: epoch) ?? epoch
    }

    /// Replace any date separator (`. , / -`) with `sep`, keeping digits.
    private static func normalized(_ s: String, to sep: String) -> String {
        String(s.map { ($0 == "." || $0 == "," || $0 == "/" || $0 == "-") ? Character(sep) : $0 })
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        DateFieldParser.makeFormatter(pattern)
    }

    /// Midnight → noon (rows lacking a time land at 12:00, matching the importer).
    static func noon(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        if (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 {
            return cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }
        return date
    }
}

/// Direction resolution for the bank/report families (B, C). Base direction comes
/// from the debit/credit split (D3), then a cash-move / loan marker OVERRIDES to
/// `.neutral` (A3: transfers/cash moves/loans are excluded from both totals).
enum DirectionResolver {

    /// Neutral markers as multi-word phrases so a bare "transfer" inside an
    /// INCASARE line does NOT flip an incoming payment to neutral (the client's
    /// `INCASARE |transfer` credit row must stay income). Loans are neutral too.
    static let neutralPhrases = [
        "depunere numerar", "retragere numerar", "schimb valutar",
        "imprumut", "restituire",
    ]

    /// Whether a folded description/category marks a neutral cash-move/loan.
    static func isNeutral(_ folded: String) -> Bool {
        neutralPhrases.contains { folded.contains($0) }
    }

    /// Fold + resolve: neutral marker wins; else debit→expense / credit→income.
    static func resolve(debit: Bool, credit: Bool, marker text: String) -> TransactionDirection {
        if isNeutral(Categorizer.normalize(text)) { return .neutral }
        if credit && !debit { return .income }
        return .expense
    }
}
