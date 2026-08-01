import XCTest
@testable import Bani

/// CoreXLSX reading of the bundled `.xlsx` fixture: shared strings, densified
/// columns, and — the point of the fixture — real Excel serial dates resolved
/// from the cell's number-format style.
final class XLSXReaderTests: XCTestCase {

    private func day(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    func testReadsHeadersRowsAndSharedStrings() throws {
        let doc = try XLSXReader.parse(data: ImportTestSupport.sampleXLSX(), fileName: "sample.xlsx")
        XCTAssertEqual(doc.kind, .xlsx)
        let sheet = try XCTUnwrap(doc.sheets.first)
        XCTAssertEqual(sheet.name, "Cheltuieli")
        XCTAssertEqual(sheet.headers, ["Data", "Suma", "Descriere", "Categorie"])
        XCTAssertEqual(sheet.rows.count, 2)
        XCTAssertEqual(sheet.rows[0].text(at: 1), "25000")
        XCTAssertEqual(sheet.rows[0].text(at: 2), "Chirie")
        XCTAssertEqual(sheet.rows[0].text(at: 3), "Utilitati")
        XCTAssertEqual(sheet.rows[1].text(at: 1), "12.5")
    }

    func testResolvesSerialDatesFromStyle() throws {
        let doc = try XLSXReader.parse(data: ImportTestSupport.sampleXLSX(), fileName: "sample.xlsx")
        let sheet = try XCTUnwrap(doc.sheets.first)

        let firstDate = try XCTUnwrap(sheet.rows[0].cell(at: 0)?.serialDate,
                                      "date-formatted serial cell should resolve a Date")
        let c1 = day(firstDate)
        XCTAssertEqual(c1.year, 2024); XCTAssertEqual(c1.month, 12); XCTAssertEqual(c1.day, 31)

        let secondDate = try XCTUnwrap(sheet.rows[1].cell(at: 0)?.serialDate)
        let c2 = day(secondDate)
        XCTAssertEqual(c2.year, 2025); XCTAssertEqual(c2.month, 1); XCTAssertEqual(c2.day, 1)

        // A non-date numeric cell (amount) must NOT be treated as a serial date.
        XCTAssertNil(sheet.rows[0].cell(at: 1)?.serialDate)
    }

    func testDocumentReaderDispatchesToXLSX() throws {
        let doc = try DocumentReader.read(data: ImportTestSupport.sampleXLSX(), fileName: "sample.xlsx")
        XCTAssertEqual(doc.kind, .xlsx)
        XCTAssertEqual(doc.sheets.first?.rows.count, 2)
    }

    func testDateFormatDetectionPrefersSerialForXLSX() throws {
        let doc = try XLSXReader.parse(data: ImportTestSupport.sampleXLSX(), fileName: "sample.xlsx")
        let sheet = try XCTUnwrap(doc.sheets.first)
        let dateCells = sheet.rows.compactMap { $0.cell(at: 0) }
        let detection = DateFieldParser.detect(samples: dateCells)
        XCTAssertEqual(detection.format, .excelSerial)
        XCTAssertFalse(detection.ambiguous)
    }

    func testCustomDateFormatCodeHeuristic() {
        XCTAssertTrue(XLSXReader.looksLikeDateFormat("dd/mm/yyyy"))
        XCTAssertTrue(XLSXReader.looksLikeDateFormat("[$-409]d\\-mmm\\-yy"))
        XCTAssertTrue(XLSXReader.looksLikeDateFormat("mm:ss"))
        XCTAssertFalse(XLSXReader.looksLikeDateFormat("#,##0.00"))
        XCTAssertFalse(XLSXReader.looksLikeDateFormat("0.00%"))
        XCTAssertFalse(XLSXReader.looksLikeDateFormat("#,##0.00 \"lei\""))
    }
}
