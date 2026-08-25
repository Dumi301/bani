import XCTest
@testable import Bani

/// P7 gate — the one-way `.xlsx` relay. Golden-file content assertions on the
/// worksheet XML both exporters produce, PLUS a full round-trip: the exported bytes
/// re-imported through the EXISTING `XLSXReader` (CoreXLSX) path yield exactly the
/// rows written. A separate structural check proves the hand-rolled store-only ZIP
/// (`StoreZipWriter`) is CRC-correct enough for the proven `MinimalZip` reader to
/// locate an entry inside it.
final class RaportExportTests: XCTestCase {

    // MARK: - Centralizator pivot

    private var centralizatorInput: [CentralizatorPivotExporter.Row] {
        [
            .init(category: "Materiale", amount: 100, isCredit: false),
            .init(category: "Materiale", amount: 50, isCredit: false),
            .init(category: "Salariu", amount: 5000, isCredit: true),
        ]
    }

    func testCentralizatorGoldenWorksheetXML() {
        let rows = CentralizatorPivotExporter.rows(centralizatorInput)
        let xml = XLSXWriter.worksheetXML(rows)

        // Header (RO) + both category rows (sorted asc) + grand total, with the
        // computed count/sum measures.
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">CATEGORIE</t>"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Materiale</t>"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Salariu</t>"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">TOTAL GENERAL</t>"))
        // Materiale: 2 debit rows summing 150.
        XCTAssertTrue(xml.contains("<v>150</v>"))
        // Salariu: 1 credit row summing 5000; grand total credit also 5000.
        XCTAssertTrue(xml.contains("<v>5000</v>"))
    }

    func testCentralizatorRoundTripsThroughXLSXReader() throws {
        let data = CentralizatorPivotExporter.xlsx(centralizatorInput)
        let doc = try XLSXReader.parse(data: data, fileName: "Centralizator.xlsx")

        let sheet = try XCTUnwrap(doc.sheets.first)
        XCTAssertEqual(sheet.name, "Centralizator")
        XCTAssertEqual(sheet.headers, ["CATEGORIE", "Nr. debit", "Nr. credit", "Debit", "Credit"])
        XCTAssertEqual(sheet.rows.count, 3)   // Materiale, Salariu, TOTAL GENERAL

        let materiale = try XCTUnwrap(sheet.rows.first { $0.cells.first?.text == "Materiale" })
        XCTAssertEqual(materiale.cells[1].text, "2")     // debit count
        XCTAssertEqual(materiale.cells[3].text, "150")   // debit sum

        let grand = try XCTUnwrap(sheet.rows.first { $0.cells.first?.text == "TOTAL GENERAL" })
        XCTAssertEqual(grand.cells[4].text, "5000")      // credit sum
    }

    // MARK: - Raport Custom

    private var raportContent: RaportCustomExporter.Content {
        RaportCustomExporter.Content(sections: [
            .init(title: "Poziție", lines: [
                .init(label: "Poziție netă", value: 1500),
                .init(label: "Liber de investit", value: 3000),
            ]),
            .init(title: "Datorii — bancă", lines: [
                .init(label: "Credit BCR", value: 11_000),
            ]),
        ])
    }

    func testRaportCustomGoldenWorksheetXML() {
        let xml = XLSXWriter.worksheetXML(RaportCustomExporter.rows(raportContent))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Indicator</t>"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Valoare (RON)</t>"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">Poziție netă</t>"))
        XCTAssertTrue(xml.contains("<v>1500</v>"))
        XCTAssertTrue(xml.contains("<v>11000</v>"))
    }

    func testRaportCustomRoundTripsThroughXLSXReader() throws {
        let data = RaportCustomExporter.xlsx(raportContent)
        let doc = try XLSXReader.parse(data: data, fileName: "Raport.xlsx")

        let sheet = try XCTUnwrap(doc.sheets.first)
        XCTAssertEqual(sheet.name, "Raport")
        XCTAssertEqual(sheet.headers, ["Indicator", "Valoare (RON)"])

        let netRow = try XCTUnwrap(sheet.rows.first { $0.cells.first?.text == "Poziție netă" })
        XCTAssertEqual(netRow.cells[1].text, "1500")
        let bankRow = try XCTUnwrap(sheet.rows.first { $0.cells.first?.text == "Credit BCR" })
        XCTAssertEqual(bankRow.cells[1].text, "11000")
    }

    // MARK: - Store ZIP structural validity

    func testStoreZipIsReadableByMinimalZip() throws {
        let data = CentralizatorPivotExporter.xlsx(centralizatorInput)
        // The proven read-only extractor must locate the worksheet part inside the
        // hand-rolled store-only archive (validates local/central header + CRC layout).
        let sheetBytes = try XCTUnwrap(
            MinimalZip.extract(entrySuffix: "xl/worksheets/sheet1.xml", from: data),
            "the store-only zip must expose the worksheet entry to MinimalZip"
        )
        let xml = String(decoding: sheetBytes, as: UTF8.self)
        XCTAssertTrue(xml.contains("<worksheet"))
        XCTAssertTrue(xml.contains("TOTAL GENERAL"))
    }

    func testContentTypesEntryIsPresent() throws {
        let data = RaportCustomExporter.xlsx(raportContent)
        let ct = try XCTUnwrap(MinimalZip.extract(entrySuffix: "[Content_Types].xml", from: data))
        XCTAssertTrue(String(decoding: ct, as: UTF8.self).contains("spreadsheetml.sheet.main+xml"))
    }
}
