import Foundation

/// Shared, `Sendable` value types the import pipeline speaks in. Both the native
/// CSV parser and the CoreXLSX reader normalize their input into a
/// `TabularDocument` so everything downstream (header guessing, mapping, preview,
/// execution) is source-agnostic and unit-testable with no file I/O.

/// The two importable file kinds.
enum ImportFileKind: String, Sendable, Equatable {
    case csv
    case xlsx
}

/// One parsed cell. `text` is the trimmed display/parse string. `serialDate` is
/// set ONLY for an .xlsx cell that is numeric AND carries a date number-format —
/// i.e. a real Excel serial date already resolved to a `Date` via CoreXLSX. CSV
/// and text cells always leave it `nil` (their dates are strings, parsed later).
struct SheetCell: Equatable, Sendable {
    var text: String
    var serialDate: Date?

    init(text: String, serialDate: Date? = nil) {
        self.text = text
        self.serialDate = serialDate
    }

    var isEmpty: Bool { text.isEmpty }
}

/// One data row, positional by column. Short rows are padded to the header width
/// by the reader, so `text(at:)` is always safe.
struct SheetRow: Equatable, Sendable {
    var cells: [SheetCell]
    /// 1-based source line (CSV) / spreadsheet row (xlsx) for skip reporting.
    var sourceRow: Int

    func cell(at index: Int) -> SheetCell? {
        (index >= 0 && index < cells.count) ? cells[index] : nil
    }
    func text(at index: Int) -> String { cell(at: index)?.text ?? "" }

    /// Whether every cell is empty (a blank line to be dropped).
    var isBlank: Bool { cells.allSatisfy(\.isEmpty) }
}

/// One table: a header row plus its data rows. For .xlsx this is a single
/// worksheet; a CSV document always has exactly one sheet.
struct TabularSheet: Equatable, Sendable, Identifiable {
    /// Stable identity for the sheet picker (sheet name or a synthesized index).
    var id: String
    /// Display name — the worksheet name (xlsx) or `nil` (csv).
    var name: String?
    var headers: [String]
    var rows: [SheetRow]

    var columnCount: Int { headers.count }
    var rowCount: Int { rows.count }
}

/// A whole importable document. A CSV always yields exactly one sheet; an .xlsx
/// yields one per worksheet (the wizard shows a sheet picker when > 1).
struct TabularDocument: Sendable {
    var fileName: String
    var kind: ImportFileKind
    var sheets: [TabularSheet]
}

/// Failures surfaced by the readers, each with a localized user-facing message.
enum ImportReadError: Error, Equatable, LocalizedError {
    case unsupportedType
    case emptyFile
    case corruptArchive
    case noSheets
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedType: String(localized: "import.error.unsupportedType")
        case .emptyFile:       String(localized: "import.error.emptyFile")
        case .corruptArchive:  String(localized: "import.error.corruptArchive")
        case .noSheets:        String(localized: "import.error.noSheets")
        case .decodingFailed:  String(localized: "import.error.decodingFailed")
        }
    }
}
