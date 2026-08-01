import XCTest
@testable import Bani

/// End-to-end row validation: required-field skips + reasons, negatives policy,
/// currency/context resolution, category source, and fingerprinting.
final class ImportRowParserTests: XCTestCase {

    private func sheet(_ headers: [String], _ rows: [[String]]) -> TabularSheet {
        let sheetRows = rows.enumerated().map { i, cols in
            SheetRow(cells: cols.map { SheetCell(text: $0) }, sourceRow: i + 2)
        }
        return TabularSheet(id: "t", name: nil, headers: headers, rows: sheetRows)
    }

    private func baseMapping() -> ImportFieldMapping {
        var m = ImportFieldMapping()
        m.dateColumn = 0; m.amountColumn = 1; m.descriptionColumn = 2
        m.categoryColumn = 3; m.contextColumn = 4
        m.dateFormat = .dayFirstDot
        return m
    }

    private let rows = [
        ["15.03.2024", "1.234,56", "Chirie", "Utilitati", "munca"],      // valid
        ["", "50", "NoDate", "Alimente", "personal"],                     // missing date
        ["16.03.2024", "abc", "BadAmount", "Alimente", "personal"],       // unparseable amount
        ["17.03.2024", "-50,00", "Rambursare", "Altele", "personal"],     // negative
        ["18.03.2024", "10", "", "Alimente", "personal"],                 // missing description
    ]

    func testAbsoluteNegativesPolicy() {
        var mapping = baseMapping(); mapping.negativesPolicy = .absolute
        let result = ImportRowParser.parse(sheet: sheet(["Data","Suma","Descriere","Categorie","Context"], rows), mapping: mapping)

        XCTAssertEqual(result.rows.count, 2)             // Chirie + Rambursare(abs)
        XCTAssertEqual(result.skipped.count, 3)
        XCTAssertTrue(result.negativesFound)

        let chirie = result.rows[0]
        XCTAssertEqual(chirie.amount, Decimal(string: "1234.56"))
        XCTAssertEqual(chirie.context, .work)            // "munca" → work
        XCTAssertEqual(chirie.currency, .ron)            // no currency column → fixed RON default
        XCTAssertEqual(chirie.categorySource, .columnValue("Utilitati"))
        XCTAssertFalse(chirie.fingerprint.isEmpty)

        let neg = result.rows[1]
        XCTAssertEqual(neg.amount, Decimal(50))          // imported as positive
        XCTAssertEqual(neg.context, .personal)

        XCTAssertEqual(result.distinctCategoryValues, ["Utilitati", "Altele"])
    }

    func testSkipNegativesPolicy() {
        var mapping = baseMapping(); mapping.negativesPolicy = .skip
        let result = ImportRowParser.parse(sheet: sheet(["Data","Suma","Descriere","Categorie","Context"], rows), mapping: mapping)
        XCTAssertEqual(result.rows.count, 1)             // only Chirie
        XCTAssertEqual(result.skipped.count, 4)
        XCTAssertTrue(result.skipped.contains { $0.reason == .negativeSkipped })
    }

    func testSkipReasonsAreSpecific() {
        let result = ImportRowParser.parse(sheet: sheet(["Data","Suma","Descriere","Categorie","Context"], rows), mapping: baseMapping())
        let reasons = Set(result.skipped.map(\.reason))
        XCTAssertTrue(reasons.contains(.missingDate))
        XCTAssertTrue(reasons.contains(.unparseableAmount))
        XCTAssertTrue(reasons.contains(.missingDescription))
    }

    func testNoCategoryColumnUsesByDescription() {
        var mapping = baseMapping(); mapping.categoryColumn = nil
        let result = ImportRowParser.parse(sheet: sheet(["Data","Suma","Descriere","Categorie","Context"], rows), mapping: mapping)
        XCTAssertTrue(result.rows.allSatisfy { $0.categorySource == .byDescription })
        XCTAssertTrue(result.distinctCategoryValues.isEmpty)
    }

    func testFixedContextAndCurrencyColumn() {
        var mapping = ImportFieldMapping()
        mapping.dateColumn = 0; mapping.amountColumn = 1; mapping.descriptionColumn = 2
        mapping.currencyColumn = 3            // currency from a column
        mapping.contextColumn = nil           // fixed context
        mapping.fixedContext = .work
        mapping.dateFormat = .dayFirstDot
        let s = sheet(["Data","Suma","Descriere","Moneda"], [
            ["15.03.2024", "10", "EUR expense", "EUR"],
            ["16.03.2024", "20", "RON expense", "lei"],
        ])
        let result = ImportRowParser.parse(sheet: s, mapping: mapping)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].currency, .eur)
        XCTAssertEqual(result.rows[1].currency, .ron)
        XCTAssertTrue(result.rows.allSatisfy { $0.context == .work })   // fixed
    }
}
