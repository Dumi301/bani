import Foundation
import CoreXLSX

/// Reads an .xlsx workbook into `TabularSheet`s via CoreXLSX (the one sanctioned
/// dependency). Resolves shared strings, densifies sparse rows into positional
/// columns, and — crucially — turns real Excel serial dates into `Date`s by
/// consulting each cell's number-format style, so a numeric date cell imports as
/// a date and never as a raw serial like `45000`.
enum XLSXReader {

    /// Parse .xlsx bytes into a multi-sheet `TabularDocument` (one sheet per
    /// worksheet, in workbook order).
    static func parse(data: Data, fileName: String) throws -> TabularDocument {
        guard !data.isEmpty else { throw ImportReadError.emptyFile }
        let file: XLSXFile
        do {
            file = try XLSXFile(data: data)
        } catch {
            throw ImportReadError.corruptArchive
        }

        let sharedStrings = try? file.parseSharedStrings()
        let styles = try? file.parseStyles()
        let dateStyles = dateFormattedStyleIndices(styles)

        var sheets: [TabularSheet] = []
        let workbooks = (try? file.parseWorkbooks()) ?? []
        for workbook in workbooks {
            let pathsAndNames = (try? file.parseWorksheetPathsAndNames(workbook: workbook)) ?? []
            for (offset, item) in pathsAndNames.enumerated() {
                guard let worksheet = try? file.parseWorksheet(at: item.path) else { continue }
                let sheet = buildSheet(
                    worksheet,
                    name: item.name,
                    index: sheets.count + offset,
                    sharedStrings: sharedStrings,
                    dateStyles: dateStyles
                )
                sheets.append(sheet)
            }
        }

        guard !sheets.isEmpty else { throw ImportReadError.noSheets }
        return TabularDocument(fileName: fileName, kind: .xlsx, sheets: sheets)
    }

    /// Parse .xlsx bytes into FULL positional grids (`RawDocument`) — every row of
    /// every worksheet, nothing stripped — for the one-tap family pipeline (D).
    /// Reuses the same shared-string / serial-date resolution as `parse`.
    static func parseRaw(data: Data, fileName: String) throws -> RawDocument {
        guard !data.isEmpty else { throw ImportReadError.emptyFile }
        let file: XLSXFile
        do { file = try XLSXFile(data: data) } catch { throw ImportReadError.corruptArchive }

        let sharedStrings = try? file.parseSharedStrings()
        let styles = try? file.parseStyles()
        let dateStyles = dateFormattedStyleIndices(styles)

        var sheets: [RawSheet] = []
        let workbooks = (try? file.parseWorkbooks()) ?? []
        for workbook in workbooks {
            let pathsAndNames = (try? file.parseWorksheetPathsAndNames(workbook: workbook)) ?? []
            for (offset, item) in pathsAndNames.enumerated() {
                guard let worksheet = try? file.parseWorksheet(at: item.path) else { continue }
                let rows = rawRows(worksheet, sharedStrings: sharedStrings, dateStyles: dateStyles)
                sheets.append(RawSheet(id: item.name ?? "sheet\(sheets.count + offset + 1)", name: item.name, rows: rows))
            }
        }
        guard !sheets.isEmpty else { throw ImportReadError.noSheets }
        return RawDocument(fileName: fileName, kind: .xlsx, sheets: sheets)
    }

    /// Densify every row of a worksheet into positional `SheetCell`s (blanks
    /// included) — the shared core behind both `buildSheet` and `parseRaw`.
    private static func rawRows(_ worksheet: Worksheet, sharedStrings: SharedStrings?, dateStyles: Set<Int>) -> [SheetRow] {
        let raw = worksheet.data?.rows ?? []
        let columnA = ColumnReference("A")!
        var width = 0
        for row in raw {
            for cell in row.cells {
                width = max(width, columnA.distance(to: cell.reference.column) + 1)
            }
        }
        return raw.map { row in
            var cells = Array(repeating: SheetCell(text: ""), count: width)
            for cell in row.cells {
                let idx = columnA.distance(to: cell.reference.column)
                guard idx >= 0, idx < width else { continue }
                cells[idx] = SheetCell(
                    text: cellText(cell, sharedStrings: sharedStrings),
                    serialDate: serialDate(cell, dateStyles: dateStyles),
                    numericValue: numericValue(cell, dateStyles: dateStyles)
                )
            }
            return SheetRow(cells: cells, sourceRow: Int(row.reference))
        }
    }

    // MARK: - Sheet building

    private static func buildSheet(
        _ worksheet: Worksheet,
        name: String?,
        index: Int,
        sharedStrings: SharedStrings?,
        dateStyles: Set<Int>
    ) -> TabularSheet {
        let rawRows = worksheet.data?.rows ?? []

        // Column width = widest column reference across every row (dense layout).
        let columnA = ColumnReference("A")!
        var width = 0
        for row in rawRows {
            for cell in row.cells {
                let idx = columnA.distance(to: cell.reference.column) // 0-based
                width = max(width, idx + 1)
            }
        }

        // Densify each row into a positional [SheetCell] of `width`.
        func dense(_ row: Row) -> SheetRow {
            var cells = Array(repeating: SheetCell(text: ""), count: width)
            for cell in row.cells {
                let idx = columnA.distance(to: cell.reference.column)
                guard idx >= 0, idx < width else { continue }
                cells[idx] = SheetCell(
                    text: cellText(cell, sharedStrings: sharedStrings),
                    serialDate: serialDate(cell, dateStyles: dateStyles),
                    numericValue: numericValue(cell, dateStyles: dateStyles)
                )
            }
            return SheetRow(cells: cells, sourceRow: Int(row.reference))
        }

        // Header = first non-blank row; data = subsequent non-blank rows.
        var headers: [String] = []
        var dataRows: [SheetRow] = []
        var headerFound = false
        for row in rawRows {
            let dr = dense(row)
            if dr.isBlank { continue }
            if !headerFound {
                headers = dr.cells.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                headerFound = true
            } else {
                dataRows.append(dr)
            }
        }

        return TabularSheet(
            id: name ?? "sheet\(index + 1)",
            name: name,
            headers: headers,
            rows: dataRows
        )
    }

    // MARK: - Cell value resolution

    private static func cellText(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let ss = sharedStrings {
            if let s = cell.stringValue(ss) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rich = cell.richStringValue(ss).compactMap(\.text).joined()
            if !rich.isEmpty { return rich.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let inline = cell.inlineString?.text {
            return inline.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (cell.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A resolved `Date` when the cell is a numeric, date-number-formatted serial
    /// value; `nil` otherwise (text cells, or numbers without a date format).
    private static func serialDate(_ cell: Cell, dateStyles: Set<Int>) -> Date? {
        guard let styleIndex = cell.styleIndex, dateStyles.contains(styleIndex) else { return nil }
        switch cell.type {
        case .sharedString, .string, .inlineStr, .bool, .error:
            return nil
        default:
            return cell.dateValue
        }
    }

    /// The cell's real stored number as money (`Decimal` rounded to 2dp) when the
    /// cell is numeric and NOT a date; `nil` for text/bool/error/date cells. Reads
    /// the raw `<v>` via `Double` so Excel float-dust (displayed "34.839,70" stored
    /// as `34839.699999999997`) and scientific notation (`3.4E7`) resolve to the
    /// intended amount instead of being re-lexed from the raw string. The import
    /// prefers this over `AmountLexer.parseCell(text)` for the amount column.
    private static func numericValue(_ cell: Cell, dateStyles: Set<Int>) -> Decimal? {
        // Date-styled numeric cells go down the `serialDate` path, not here.
        if let styleIndex = cell.styleIndex, dateStyles.contains(styleIndex) { return nil }
        // Same non-numeric cell types the serial-date resolver excludes. A native
        // ISO-date cell (`t="d"`) falls to `default` and its `Double(...)` fails, so
        // it correctly yields `nil` without naming a possibly-absent `.date` case.
        switch cell.type {
        case .sharedString, .string, .inlineStr, .bool, .error:
            return nil
        default:
            guard let raw = cell.value, let d = Double(raw) else { return nil }
            return AmountLexer.roundedMoney(Decimal(d))
        }
    }

    // MARK: - Date-format style detection

    /// Excel builtin number-format IDs that denote a date and/or time.
    private static let builtinDateFormatIDs: Set<Int> =
        Set(14...22).union(27...36).union([45, 46, 47]).union(50...58)

    /// The set of cell-format (style) indices whose number format is a date/time,
    /// so a numeric cell using one is a real serial date.
    private static func dateFormattedStyleIndices(_ styles: Styles?) -> Set<Int> {
        guard let styles, let formats = styles.cellFormats?.items else { return [] }
        var customCodes: [Int: String] = [:]
        for nf in styles.numberFormats?.items ?? [] { customCodes[nf.id] = nf.formatCode }

        var out: Set<Int> = []
        for (idx, format) in formats.enumerated() {
            let id = format.numberFormatId
            if builtinDateFormatIDs.contains(id) {
                out.insert(idx)
            } else if let code = customCodes[id], looksLikeDateFormat(code) {
                out.insert(idx)
            }
        }
        return out
    }

    /// Heuristic date/time detection for a custom number-format code: strip quoted
    /// literals, `[...]` sections, and `\`-escapes, then look for date/time tokens.
    static func looksLikeDateFormat(_ code: String) -> Bool {
        var cleaned = ""
        var inQuote = false
        var inBracket = false
        var escaped = false
        for ch in code {
            if escaped { escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case "\"": inQuote.toggle()
            case "[": inBracket = true
            case "]": inBracket = false
            default:
                if !inQuote && !inBracket { cleaned.append(ch) }
            }
        }
        let lower = cleaned.lowercased()
        if lower.contains("y") || lower.contains("d") || lower.contains("h") || lower.contains("s") {
            return true
        }
        // Month/minute "m" is ambiguous alone; treat as a date only with a
        // date/time separator present.
        if lower.contains("m") && (lower.contains("/") || lower.contains("-") || lower.contains(":")) {
            return true
        }
        return false
    }
}
