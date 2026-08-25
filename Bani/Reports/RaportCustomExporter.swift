import Foundation

/// One-way export #1 (VISION §1 "info relay → Excel"): the Raport hub's own
/// numbers as a single-sheet `.xlsx`, a readable 2-column `Indicator | Valoare
/// (RON)` layout with Romanian headers (the client's language). Sections mirror
/// Board 2: Poziție, Datorii — bancă, Datorii — investitori, Proiecte.
///
/// Pure: it renders a value-typed `RaportExportContent` (built by the hub from
/// `RaportHubModel`) into a cell grid, then hands off to `XLSXWriter`. Golden-file +
/// round-trip proven in `RaportExportTests`.
enum RaportCustomExporter {

    /// One labelled money line (RON) in the report.
    struct Line: Equatable, Sendable {
        var label: String
        var value: Decimal
    }

    /// A titled group of lines (a Board-2 section).
    struct Section: Equatable, Sendable {
        var title: String
        var lines: [Line]
    }

    /// The whole report payload — ordered sections of labelled RON values.
    struct Content: Equatable, Sendable {
        var sections: [Section]
    }

    /// The worksheet tab name.
    static let sheetName = "Raport"

    /// The RO header row (row 1) — the reader treats row 1 as the header.
    static let header: [String] = ["Indicator", "Valoare (RON)"]

    /// Build the cell grid: header row, then per section a title row followed by its
    /// labelled value rows.
    static func rows(_ content: Content) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [header.map { XLSXCell.text($0) }]
        for section in content.sections {
            rows.append([.text(section.title), .blank])
            for line in section.lines {
                rows.append([.text(line.label), .number(line.value)])
            }
        }
        return rows
    }

    /// The finished `.xlsx` bytes.
    static func xlsx(_ content: Content) -> Data {
        XLSXWriter.workbook(sheetName: sheetName, rows: rows(content))
    }
}
