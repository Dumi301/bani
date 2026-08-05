import XCTest
@testable import Bani

/// Bug B — the reader now resolves numeric .xlsx cells as NUMBERS (float-dust safe)
/// and the generic tabular import prefers that resolved value, caps implausible
/// amounts, and surfaces them in the understanding report. Driven by the synthetic
/// `numeric_amounts.xlsx` fixture (no client data):
///   • B2  numeric `34839.699999999997`, money-styled  → 34839.70
///   • B3  numeric `3.48397E4` (scientific notation)   → 34839.70
///   • B4  text     `"34.839,70"`                       → 34839.70 (string lexer)
///   • B5  numeric `999999999999`                       → implausible → skipped
final class XLSXNumericCellTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    // MARK: - Reader resolves numeric cells as money

    func testReaderResolvesNumericAmountsAsMoney() throws {
        let doc = try XLSXReader.parse(data: ImportTestSupport.numericAmountsXLSX(), fileName: "numeric_amounts.xlsx")
        let sheet = try XCTUnwrap(doc.sheets.first)
        XCTAssertEqual(sheet.headers, ["Data", "Suma", "Descriere"])
        XCTAssertEqual(sheet.rows.count, 4)

        // Float-dust money cell → clean 2dp value (the reported-bug cell).
        XCTAssertEqual(try XCTUnwrap(sheet.rows[0].cell(at: 1)?.numericValue), dec("34839.70"))
        // Scientific-notation numeric cell → the same money value.
        XCTAssertEqual(try XCTUnwrap(sheet.rows[1].cell(at: 1)?.numericValue), dec("34839.70"))
        // Genuine text amount: no resolved numericValue, but the string lexer reads
        // it to the same money value.
        XCTAssertNil(sheet.rows[2].cell(at: 1)?.numericValue)
        XCTAssertEqual(sheet.rows[2].cell(at: 1)?.text, "34.839,70")
        XCTAssertEqual(AmountLexer.parseCell(try XCTUnwrap(sheet.rows[2].cell(at: 1)?.text))?.magnitude, dec("34839.70"))
        // Implausible numeric cell — the reader resolves the number; the cap lives
        // in classification (below), so it is never silently altered here.
        XCTAssertEqual(try XCTUnwrap(sheet.rows[3].cell(at: 1)?.numericValue), dec("999999999999"))
        XCTAssertEqual(AmountLexer.classify(numeric: try XCTUnwrap(sheet.rows[3].cell(at: 1)?.numericValue)), .implausible)
    }

    func testDateCellsStayDatesNotNumericValues() throws {
        let doc = try XLSXReader.parse(data: ImportTestSupport.numericAmountsXLSX(), fileName: "numeric_amounts.xlsx")
        let sheet = try XCTUnwrap(doc.sheets.first)
        // The date column resolves serial dates and carries NO numericValue.
        XCTAssertNotNil(sheet.rows[0].cell(at: 0)?.serialDate)
        XCTAssertNil(sheet.rows[0].cell(at: 0)?.numericValue)
    }

    // MARK: - End-to-end generic tabular import over the fixture

    func testGenericImportProducesCleanAmountsAndFlagsImplausible() throws {
        let raw = try XLSXReader.parseRaw(data: ImportTestSupport.numericAmountsXLSX(), fileName: "numeric_amounts.xlsx")
        let sheet = try XCTUnwrap(raw.sheets.first)

        let outcome = GenericSheetImport.run(sheet, context: .personal)
        XCTAssertTrue(outcome.mappingComplete, "Data/Suma/Descriere must auto-map")

        // ✓ — the three good rows import with the correct money value, never the
        // phantom 34_839_699_999_999_997.
        XCTAssertEqual(outcome.drafts.count, 3)
        XCTAssertTrue(outcome.drafts.allSatisfy { $0.amount == dec("34839.70") },
                      "amounts: \(outcome.drafts.map(\.amount))")
        XCTAssertFalse(outcome.drafts.contains { $0.amount > AmountLexer.plausibilityCap })

        // ⚠ — the implausible row is skipped AND surfaced in the report, never
        // silently committed or silently dropped.
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertTrue(outcome.noteKeys.contains("import.note.implausibleAmount"),
                      "report notes: \(outcome.noteKeys)")
    }
}
