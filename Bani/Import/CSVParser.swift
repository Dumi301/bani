import Foundation

/// Native CSV reader — Foundation only, no dependency (only .xlsx justifies one).
/// Handles the shapes a real exported expense sheet throws at it:
///   • quoted fields with embedded delimiters, newlines, and escaped `""` quotes,
///   • both `,` and `;` delimiters (and tab, a common "Unicode text" export),
///     auto-detected from the header line,
///   • a UTF-8 or UTF-16 (LE/BE) byte-order mark,
///   • CRLF, LF, or lone-CR line endings.
///
/// Pure value logic, `Sendable`.
enum CSVParser {

    /// Parse raw file bytes into a single-sheet `TabularDocument`. The first
    /// non-blank row becomes the header; remaining non-blank rows are data.
    static func parse(data: Data, fileName: String) throws -> TabularDocument {
        // Normalize line endings FIRST. Swift treats "\r\n" as a single Character
        // (grapheme cluster), so a char-by-char state machine never sees a bare
        // "\r" or "\n" in a CRLF file (the common Excel export) — collapsing to
        // "\n" up front makes row splitting reliable.
        let text = normalizeLineEndings(decode(data))
        guard !text.isEmpty else { throw ImportReadError.emptyFile }

        let delimiter = detectDelimiter(text)
        let rawRows = parseRows(text, delimiter: delimiter)

        // Drop leading/trailing fully-empty rows; find the header (first non-blank).
        var records = rawRows
        // Trim trailing all-empty records (common from a trailing newline).
        while let last = records.last, last.allSatisfy({ $0.isEmpty }) { records.removeLast() }
        guard let headerIndex = records.firstIndex(where: { !$0.allSatisfy(\.isEmpty) }) else {
            throw ImportReadError.emptyFile
        }

        let headerFields = records[headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let width = max(headerFields.count, records.dropFirst(headerIndex + 1).map(\.count).max() ?? 0)
        let headers = pad(headerFields, to: width)

        var rows: [SheetRow] = []
        // `sourceRow` is 1-based over the ORIGINAL record order so skip reasons
        // point at the real line the user sees.
        for (offset, record) in records.enumerated() where offset > headerIndex {
            let fields = pad(record.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, to: width)
            let row = SheetRow(cells: fields.map { SheetCell(text: $0) }, sourceRow: offset + 1)
            if row.isBlank { continue }
            rows.append(row)
        }

        let sheet = TabularSheet(id: "csv", name: nil, headers: headers, rows: rows)
        return TabularDocument(fileName: fileName, kind: .csv, sheets: [sheet])
    }

    /// Parse CSV bytes into a FULL positional grid (`RawDocument`, one sheet) —
    /// every record in order, blanks included — for the one-tap family pipeline.
    /// CSV cells never carry a serial date (dates are text, parsed downstream).
    static func parseRaw(data: Data, fileName: String) throws -> RawDocument {
        let text = normalizeLineEndings(decode(data))
        guard !text.isEmpty else { throw ImportReadError.emptyFile }
        let delimiter = detectDelimiter(text)
        var records = parseRows(text, delimiter: delimiter)
        while let last = records.last, last.allSatisfy({ $0.isEmpty }) { records.removeLast() }
        let width = records.map(\.count).max() ?? 0
        let rows: [SheetRow] = records.enumerated().map { offset, record in
            let fields = pad(record.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, to: width)
            return SheetRow(cells: fields.map { SheetCell(text: $0) }, sourceRow: offset + 1)
        }
        let sheet = RawSheet(id: "csv", name: nil, rows: rows)
        return RawDocument(fileName: fileName, kind: .csv, sheets: [sheet])
    }

    // MARK: - Decoding (BOM aware)

    /// Collapse CRLF and lone CR to LF (see the grapheme-cluster note in `parse`).
    static func normalizeLineEndings(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func decode(_ data: Data) -> String {
        // UTF-16 LE / BE BOMs.
        if data.count >= 2 {
            if data[0] == 0xFF, data[1] == 0xFE {
                return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
            }
            if data[0] == 0xFE, data[1] == 0xFF {
                return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
            }
        }
        // UTF-8 BOM.
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        // No BOM: UTF-8, then a Latin-1 fallback (older Romanian exports) so
        // diacritics never silently blank the whole file.
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Delimiter detection

    private static let candidateDelimiters: [Character] = [",", ";", "\t"]

    /// Counts each candidate delimiter on the first non-empty line, OUTSIDE quotes,
    /// and picks the most frequent. Ties (or none found) default to `,`.
    static func detectDelimiter(_ text: String) -> Character {
        // First non-empty physical line, respecting quotes only enough to skip
        // quoted newlines is overkill here — the header line rarely contains one.
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for ch in firstLine {
            if ch == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if candidateDelimiters.contains(ch) { counts[ch, default: 0] += 1 }
        }
        let best = counts.max { a, b in
            if a.value != b.value { return a.value < b.value }
            // Deterministic tie-break: prefer the earlier candidate (, over ; over tab).
            return candidateDelimiters.firstIndex(of: a.key)! > candidateDelimiters.firstIndex(of: b.key)!
        }
        return best?.key ?? ","
    }

    // MARK: - RFC-4180 state machine

    /// Splits the text into records of fields, honoring quotes (embedded
    /// delimiters, newlines, and `""` escapes) and CRLF/LF/CR line endings.
    static func parseRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var i = text.startIndex

        func endField() { record.append(field); field = "" }
        func endRecord() { endField(); rows.append(record); record = [] }

        while i < text.endIndex {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")          // escaped quote ""
                        i = next
                    } else {
                        inQuotes = false            // closing quote
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case delimiter:
                    endField()
                case "\n", "\r", "\r\n":
                    // "\r\n" is a single grapheme in Swift; matching it (plus lone
                    // CR/LF) makes this robust even if called on un-normalized text.
                    endRecord()
                default:
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        // Flush the final field/record if the file didn't end on a newline.
        if !field.isEmpty || !record.isEmpty {
            endRecord()
        }
        return rows
    }

    // MARK: - Helpers

    private static func pad(_ fields: [String], to width: Int) -> [String] {
        guard fields.count < width else { return fields }
        return fields + Array(repeating: "", count: width - fields.count)
    }
}
