import XCTest
@testable import Bani

/// Native CSV parser: quoted fields with embedded delimiters, `,`/`;`/tab
/// auto-detection, UTF-8/UTF-16 BOM, and CRLF/LF/CR line endings.
final class CSVParserTests: XCTestCase {

    private func parse(_ data: Data, name: String = "t.csv") throws -> TabularSheet {
        let doc = try CSVParser.parse(data: data, fileName: name)
        return try XCTUnwrap(doc.sheets.first)
    }

    func testCommaWithQuotedEmbeddedDelimiter() throws {
        let text = "Data,Suma,Descriere\r\n15.03.2024,\"1,234.56\",\"Lidl, Cluj\"\r\n"
        let sheet = try parse(Data(text.utf8))
        XCTAssertEqual(sheet.headers, ["Data", "Suma", "Descriere"])
        XCTAssertEqual(sheet.rows.count, 1)
        XCTAssertEqual(sheet.rows[0].text(at: 1), "1,234.56")   // embedded comma survived quoting
        XCTAssertEqual(sheet.rows[0].text(at: 2), "Lidl, Cluj")
    }

    func testSemicolonDelimiterDetected() throws {
        let text = "Data;Suma;Descriere\n16.03.2024;25.000;Chirie\n"
        let sheet = try parse(Data(text.utf8))
        XCTAssertEqual(sheet.headers.count, 3)
        XCTAssertEqual(sheet.rows[0].text(at: 1), "25.000")
    }

    func testUTF8BOMStrippedFromHeader() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("Data,Suma\n10,20\n".utf8))
        let sheet = try parse(data)
        XCTAssertEqual(sheet.headers.first, "Data")   // BOM not glued to the first header
        XCTAssertEqual(sheet.rows[0].text(at: 0), "10")
    }

    func testUTF16LEBOMDecoded() throws {
        let inner = "Data,Suma\n10,20\n"
        var data = Data([0xFF, 0xFE])
        data.append(inner.data(using: .utf16LittleEndian)!)
        let sheet = try parse(data)
        XCTAssertEqual(sheet.headers, ["Data", "Suma"])
        XCTAssertEqual(sheet.rows.count, 1)
    }

    func testCRLFAndLoneCRLineEndings() throws {
        let crlf = try parse(Data("a,b\r\n1,2\r\n3,4\r\n".utf8))
        XCTAssertEqual(crlf.rows.count, 2)
        let cr = try parse(Data("a,b\r1,2\r3,4".utf8))
        XCTAssertEqual(cr.rows.count, 2)
    }

    func testEscapedQuotesInsideQuotedField() throws {
        let sheet = try parse(Data("a,b\n\"He said \"\"hi\"\"\",2\n".utf8))
        XCTAssertEqual(sheet.rows[0].text(at: 0), "He said \"hi\"")
    }

    func testBlankLinesAndRaggedRowsPadded() throws {
        let sheet = try parse(Data("a,b,c\n1,2\n\n3,4,5,6\n".utf8))
        // Header widened to the widest row (4); short rows padded; blank dropped.
        XCTAssertEqual(sheet.columnCount, 4)
        XCTAssertEqual(sheet.rows.count, 2)
        XCTAssertEqual(sheet.rows[0].text(at: 2), "")   // padded
    }

    func testBundledSampleCSVLoadsThroughDocumentReader() throws {
        let doc = try DocumentReader.read(data: ImportTestSupport.sampleCSV(), fileName: "sample.csv")
        XCTAssertEqual(doc.kind, .csv)
        let sheet = try XCTUnwrap(doc.sheets.first)
        XCTAssertEqual(sheet.headers, ["Data", "Suma", "Descriere", "Categorie"])
        XCTAssertEqual(sheet.rows.count, 4)
        // ';'-delimited file; the quoted field keeps its embedded comma.
        XCTAssertEqual(sheet.rows[0].text(at: 2), "Lidl, Cluj")
    }
}
