import Foundation

/// One cell of an exported worksheet. Text cells are written as `inlineStr` (so no
/// shared-strings table is needed and the value is self-contained), numbers as a
/// bare numeric `<v>` (money stays `Decimal` to the last moment, formatted
/// locale-independently). `blank` cells are omitted from the row (a sparse layout
/// the reader densifies).
enum XLSXCell: Equatable, Sendable {
    case text(String)
    case number(Decimal)
    case blank
}

/// A hand-rolled minimal OOXML `.xlsx` writer. CoreXLSX (the app's one xlsx
/// dependency) reads workbooks but does NOT write them, so the one-way report relay
/// (VISION §1 "info relay → Excel") writes the OOXML parts itself and zips them with
/// `StoreZipWriter`. The produced archive is deliberately minimal — content types,
/// the package + workbook relationships, a trivial styles part, and a single
/// worksheet using inline strings — but complete enough that the EXISTING
/// `XLSXReader` (CoreXLSX) re-imports it and yields the exact rows written
/// (`RaportExportTests` round-trip). Row 1 of `rows` is the header row.
///
/// Structured so a later phase can unify this with the parked backup module's zip
/// writer: the ZIP concern lives entirely in `StoreZipWriter`; this type only builds
/// XML byte payloads.
enum XLSXWriter {

    /// Build a complete single-sheet `.xlsx` from a grid of cells.
    /// - `sheetName`: the worksheet's tab name (also the sheet id in the workbook).
    /// - `rows`: row-major cells; the first row is treated as the header by readers.
    static func workbook(sheetName: String, rows: [[XLSXCell]]) -> Data {
        let entries: [StoreZipWriter.Entry] = [
            .init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(path: "_rels/.rels", data: Data(rootRels.utf8)),
            .init(path: "xl/workbook.xml", data: Data(workbookXML(sheetName: sheetName).utf8)),
            .init(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRels.utf8)),
            .init(path: "xl/styles.xml", data: Data(stylesXML.utf8)),
            .init(path: "xl/worksheets/sheet1.xml", data: Data(worksheetXML(rows).utf8)),
        ]
        return StoreZipWriter.archive(entries)
    }

    // MARK: - Worksheet

    /// The `xl/worksheets/sheet1.xml` payload — the part golden-file tests assert on.
    static func worksheetXML(_ rows: [[XLSXCell]]) -> String {
        var body = ""
        for (r, row) in rows.enumerated() {
            let rowNumber = r + 1
            var cellsXML = ""
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(rowNumber)"
                switch cell {
                case .blank:
                    continue
                case .text(let value):
                    cellsXML += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                case .number(let value):
                    cellsXML += "<c r=\"\(ref)\"><v>\(number(value))</v></c>"
                }
            }
            body += "<row r=\"\(rowNumber)\">\(cellsXML)</row>"
        }
        return "\(xmlDecl)<worksheet xmlns=\"\(nsMain)\"><sheetData>\(body)</sheetData></worksheet>"
    }

    // MARK: - Fixed package parts

    private static let xmlDecl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static func workbookXML(sheetName: String) -> String {
        """
        \(xmlDecl)\
        <workbook xmlns="\(nsMain)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(escape(sheetName))" sheetId="1" r:id="rId1"/></sheets>\
        </workbook>
        """
    }

    private static let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    </Relationships>
    """

    /// Minimal but structurally valid styles part (one default cell format). CoreXLSX
    /// reads styles with `try?`, so this is defensive completeness, not a hard need.
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
    <fills count="1"><fill><patternFill patternType="none"/></fill></fills>\
    <borders count="1"><border/></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
    </styleSheet>
    """

    // MARK: - Formatting helpers

    /// 0-based column index → Excel column name (0→A, 25→Z, 26→AA …).
    static func columnName(_ index: Int) -> String {
        var i = index
        var name = ""
        repeat {
            let rem = i % 26
            name = String(UnicodeScalar(UInt8(65 + rem))) + name
            i = i / 26 - 1
        } while i >= 0
        return name
    }

    /// Locale-independent money string for a numeric `<v>`: rounded to 2 dp, dot
    /// decimal, no thousands separators. `Decimal.description` is inherently
    /// locale-independent (always '.', never grouped) — the exact shape the reader
    /// lexes numeric cells back from.
    static func number(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        return rounded.description
    }

    /// Escape the five predefined XML entities for element text.
    static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
