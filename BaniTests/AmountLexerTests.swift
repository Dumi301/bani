import XCTest
@testable import Bani

/// The shared `AmountLexer` — its separator-disambiguation core must stay
/// byte-for-byte equal to the parser's old `digitValue` (the `RuleBasedParser`
/// table in `ParserTests` is the companion regression), plus the import-facing
/// `parseCell` (currency words, spaces, signs, accounting parentheses).
final class AmountLexerTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    // MARK: - Separator disambiguation (shared with the parser)

    func testDigitTokenDisambiguation() {
        XCTAssertEqual(AmountLexer.value(forDigitToken: "42"), dec("42"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "25.000"), dec("25000"))   // RO thousands dot
        XCTAssertEqual(AmountLexer.value(forDigitToken: "25,000"), dec("25000"))   // EN thousands comma
        XCTAssertEqual(AmountLexer.value(forDigitToken: "1.234,56"), dec("1234.56"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "1,234.56"), dec("1234.56"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "12,50"), dec("12.50"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "12.5"), dec("12.5"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "1.000"), dec("1000"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "1.234.567"), dec("1234567"))
        XCTAssertNil(AmountLexer.value(forDigitToken: ""))
        XCTAssertNil(AmountLexer.value(forDigitToken: "abc"))
    }

    // MARK: - Free-form cell parsing (import)

    func testParseCellMagnitudes() {
        XCTAssertEqual(AmountLexer.parseCell("1.234,56"), .init(magnitude: dec("1234.56"), isNegative: false))
        XCTAssertEqual(AmountLexer.parseCell("25.000"), .init(magnitude: dec("25000"), isNegative: false))
        XCTAssertEqual(AmountLexer.parseCell("25,000"), .init(magnitude: dec("25000"), isNegative: false))
        XCTAssertEqual(AmountLexer.parseCell("42"), .init(magnitude: dec("42"), isNegative: false))
    }

    func testParseCellStripsCurrencyAndSpaces() {
        XCTAssertEqual(AmountLexer.parseCell("50 lei"), .init(magnitude: dec("50"), isNegative: false))
        XCTAssertEqual(AmountLexer.parseCell("€12.5"), .init(magnitude: dec("12.5"), isNegative: false))
        XCTAssertEqual(AmountLexer.parseCell("1 234,56"), .init(magnitude: dec("1234.56"), isNegative: false))
        XCTAssertEqual(AmountLexer.parseCell("1 234 567"), .init(magnitude: dec("1234567"), isNegative: false))
    }

    func testParseCellNegatives() {
        XCTAssertEqual(AmountLexer.parseCell("-1.234,56"), .init(magnitude: dec("1234.56"), isNegative: true))
        XCTAssertEqual(AmountLexer.parseCell("(25,00)"), .init(magnitude: dec("25"), isNegative: true))
        XCTAssertEqual(AmountLexer.parseCell("\u{2212}50"), .init(magnitude: dec("50"), isNegative: true)) // Unicode minus
    }

    func testParseCellRejectsNonAmounts() {
        XCTAssertNil(AmountLexer.parseCell(""))
        XCTAssertNil(AmountLexer.parseCell("   "))
        XCTAssertNil(AmountLexer.parseCell("0"))
        XCTAssertNil(AmountLexer.parseCell("lei"))
        XCTAssertNil(AmountLexer.parseCell("n/a"))
    }
}
