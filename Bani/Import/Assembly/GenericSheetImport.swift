import Foundation

/// The generic-tabular fast path for the one-tap flow (D2 case 2): a file that
/// matches no family signature is auto-mapped SILENTLY — header row detected
/// [bug #2], columns guessed, rows parsed — with any uncertainty (unmatched
/// mapping, ambiguous date) routed to the report rather than a wizard. The demoted
/// wizard remains reachable as the report's "fix mapping" hatch (D5).
enum GenericSheetImport {

    struct Outcome: Sendable, Equatable {
        var drafts: [DraftTransaction]
        var skippedCount: Int
        var mappingComplete: Bool
        var ambiguousDate: Bool
        var noteKeys: [String]
    }

    /// Detect the header row by scoring the first ~20 rows on known field keywords.
    static func detectHeaderRow(_ sheet: RawSheet) -> Int {
        var best = (index: 0, score: -1)
        for (i, row) in sheet.rows.prefix(20).enumerated() {
            if row.isBlank { continue }
            let headers = row.cells.map { $0.text }
            let mapping = HeaderGuesser.guess(headers: headers)
            var score = 0
            if mapping.dateColumn != nil { score += 1 }
            if mapping.amountColumn != nil { score += 1 }
            if mapping.descriptionColumn != nil { score += 1 }
            // Prefer a row with more mapped required fields; ties → earliest.
            if score > best.score { best = (i, score) }
        }
        return best.index
    }

    static func run(_ sheet: RawSheet, context: TransactionContext) -> Outcome {
        let headerRow = detectHeaderRow(sheet)
        guard headerRow < sheet.rows.count else {
            return Outcome(drafts: [], skippedCount: 0, mappingComplete: false, ambiguousDate: false, noteKeys: ["import.note.headersNotFound"])
        }
        let headers = sheet.rows[headerRow].cells.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let dataRows = Array(sheet.rows[(headerRow + 1)...].filter { !$0.isBlank })
        let tabular = TabularSheet(id: sheet.id, name: sheet.name, headers: headers, rows: dataRows)

        var mapping = HeaderGuesser.guess(headers: headers)
        guard mapping.isComplete else {
            return Outcome(drafts: [], skippedCount: dataRows.count, mappingComplete: false, ambiguousDate: false, noteKeys: ["import.note.headersNotFound"])
        }

        // Detect the date format from the mapped column's samples.
        var ambiguousDate = false
        if let dateCol = mapping.dateColumn {
            let samples = dataRows.compactMap { $0.cell(at: dateCol) }
            let detection = DateFieldParser.detect(samples: samples)
            mapping.dateFormat = detection.format
            ambiguousDate = detection.ambiguous
        }

        let parsed = ImportRowParser.parse(sheet: tabular, mapping: mapping)
        let drafts = parsed.rows.map { row -> DraftTransaction in
            let category: DraftCategory
            switch row.categorySource {
            case .byDescription: category = .byDescription
            case .uncategorized: category = .uncategorized
            case .columnValue(let value): category = FamilyCategory.resolve(value)
            }
            return DraftTransaction(
                date: row.date, amount: row.amount, currency: row.currency,
                direction: .expense, descriptionText: row.descriptionText,
                counterparty: nil, context: context, category: category, sourceRow: row.sourceRow
            )
        }
        var notes: [String] = []
        if ambiguousDate { notes.append("import.note.ambiguousDate") }
        // Surface the plausibility-cap skips as their own ⚠ line — never a silent
        // drop of an implausible amount.
        if parsed.skipped.contains(where: { $0.reason == .implausibleAmount }) {
            notes.append("import.note.implausibleAmount")
        }
        return Outcome(drafts: drafts, skippedCount: parsed.skipped.count, mappingComplete: true, ambiguousDate: ambiguousDate, noteKeys: notes)
    }
}
