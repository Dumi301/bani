import XCTest
@testable import Bani

/// Auto-guess of the column→field mapping from RO + EN header names,
/// diacritic-folded.
final class HeaderGuessTests: XCTestCase {

    func testRomanianHeaders() {
        let m = HeaderGuesser.guess(headers: ["Data", "Suma", "Descriere", "Categorie", "Moneda", "Context"])
        XCTAssertEqual(m.dateColumn, 0)
        XCTAssertEqual(m.amountColumn, 1)
        XCTAssertEqual(m.descriptionColumn, 2)
        XCTAssertEqual(m.categoryColumn, 3)
        XCTAssertEqual(m.currencyColumn, 4)
        XCTAssertEqual(m.contextColumn, 5)
    }

    func testEnglishHeaders() {
        let m = HeaderGuesser.guess(headers: ["Date", "Amount", "Description", "Category", "Currency"])
        XCTAssertEqual(m.dateColumn, 0)
        XCTAssertEqual(m.amountColumn, 1)
        XCTAssertEqual(m.descriptionColumn, 2)
        XCTAssertEqual(m.categoryColumn, 3)
        XCTAssertEqual(m.currencyColumn, 4)
    }

    func testDiacriticsFolded() {
        let m = HeaderGuesser.guess(headers: ["Dată", "Sumă", "Descriere"])
        XCTAssertEqual(m.dateColumn, 0)
        XCTAssertEqual(m.amountColumn, 1)
        XCTAssertEqual(m.descriptionColumn, 2)
        XCTAssertTrue(m.isComplete)
    }

    func testUnrecognizedHeadersLeaveRequiredUnmapped() {
        let m = HeaderGuesser.guess(headers: ["Col1", "Col2", "Col3"])
        XCTAssertNil(m.amountColumn)
        XCTAssertFalse(m.isComplete)
    }

    func testAlternateAmountSynonyms() {
        XCTAssertEqual(HeaderGuesser.guess(headers: ["Data", "Valoare", "Detalii"]).amountColumn, 1)
        XCTAssertEqual(HeaderGuesser.guess(headers: ["Data", "Total", "Detalii"]).amountColumn, 1)
    }

    func testColumnNeverDoubleAssigned() {
        // "Total" could match amount; ensure description doesn't also grab it.
        let m = HeaderGuesser.guess(headers: ["Data", "Total", "Descriere"])
        XCTAssertEqual(m.amountColumn, 1)
        XCTAssertEqual(m.descriptionColumn, 2)
        XCTAssertNotEqual(m.descriptionColumn, m.amountColumn)
    }
}
