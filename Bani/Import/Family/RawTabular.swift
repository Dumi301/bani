import Foundation

/// A worksheet as a FULL positional grid — every row (preamble, header, data,
/// blanks, footer) in workbook order, nothing stripped. The family parsers (D)
/// need this fidelity to detect the header row [bug #2], forward-fill blank dates
/// [bug #1], and exclude footers themselves — unlike `TabularSheet`, which eagerly
/// takes the first non-blank row as the header (correct for the generic wizard,
/// wrong for the client's preamble-laden files).
struct RawSheet: Sendable, Equatable, Identifiable {
    var id: String
    var name: String?
    /// Every row, positional cells, blanks included. `SheetCell.serialDate` is
    /// resolved for real Excel serial-date cells (Family A/C real dates).
    var rows: [SheetRow]

    var rowCount: Int { rows.count }

    /// The first `limit` rows' cells as folded text — the window family detection
    /// scans for a header signature.
    func headerScanWindow(_ limit: Int = 20) -> [[String]] {
        rows.prefix(limit).map { $0.cells.map { Categorizer.normalize($0.text) } }
    }
}

/// A whole importable tabular document as raw grids (one `RawSheet` per xlsx
/// worksheet; exactly one for a CSV). Lazily-friendly: the pipeline classifies
/// each sheet independently so a 100-sheet master imports in one pass [bug #5].
struct RawDocument: Sendable, Equatable {
    var fileName: String
    var kind: ImportFileKind
    var sheets: [RawSheet]
}
