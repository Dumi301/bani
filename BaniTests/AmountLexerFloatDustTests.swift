import XCTest
@testable import Bani

/// Bug B — the Excel float-dust / scientific-notation / multi-number / plausibility
/// fixes on the shared `AmountLexer`. The client's `34.839,70 lei` cell was stored
/// by Excel as `34839.699999999997` and imported as `34.839.699.999.999.997 RON`;
/// these pin the corrected behavior AND keep the thousands/decimal rules intact.
final class AmountLexerFloatDustTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
    private func mag(_ s: String) -> Decimal? { AmountLexer.parseCell(s)?.magnitude }

    // MARK: - Float dust (the reported bug)

    func testFloatDustTailsRoundToMoney() {
        XCTAssertEqual(mag("34839.699999999997"), dec("34839.70"))   // the screenshot cell
        XCTAssertEqual(mag("1149.8500000000001"), dec("1149.85"))
        XCTAssertEqual(mag("12.3456"), dec("12.35"))                 // long decimal tail → 2dp
    }

    // MARK: - Scientific notation

    func testScientificNotation() {
        XCTAssertEqual(mag("3.4E7"), dec("34000000"))
        XCTAssertEqual(mag("2.5E5"), dec("250000"))
        XCTAssertEqual(mag("3.48397E4"), dec("34839.70"))           // resolves to the same money value
    }

    // MARK: - Pinned regressions (thousands vs decimal — DO NOT change)

    func testPinnedSeparatorRules() {
        XCTAssertEqual(mag("25.000"), dec("25000"))                  // 3-trailing → thousands
        XCTAssertEqual(mag("1.234,56"), dec("1234.56"))             // both separators
        XCTAssertEqual(mag("1.234.567"), dec("1234567"))           // multi-dot thousands
        XCTAssertEqual(mag("12,50"), dec("12.50"))                  // 1–2 trailing → decimal
        XCTAssertEqual(AmountLexer.value(forDigitToken: "25.000"), dec("25000"))
        XCTAssertEqual(AmountLexer.value(forDigitToken: "1.234.567"), dec("1234567"))
    }

    // MARK: - Multi-number cells are never concatenated

    func testMultiNumberCellRejected() {
        XCTAssertNil(mag("1.200 + 300"))                            // never 1200300
        XCTAssertEqual(AmountLexer.classifyCell("1.200 + 300"), .none)
        XCTAssertNil(mag("1200 / 300"))
        XCTAssertNil(mag("12 lei 30 bani"))                         // two numbers split by letters
    }

    // MARK: - Plausibility cap

    func testPlausibilityCap() {
        XCTAssertNil(mag("150000000"))                              // > 100,000,000 → nil
        XCTAssertEqual(AmountLexer.classifyCell("150000000"), .implausible)
        XCTAssertEqual(AmountLexer.classifyCell("999999999999"), .implausible)
        XCTAssertEqual(AmountLexer.classify(numeric: dec("999999999999")), .implausible)
        // The screenshot's phantom value would have been implausible too.
        XCTAssertEqual(AmountLexer.classifyCell("34839699999999997"), .implausible)
        // Exactly at the cap is still allowed; just above is not.
        XCTAssertEqual(AmountLexer.classifyCell("100000000"), .value(.init(magnitude: dec("100000000"), isNegative: false)))
        XCTAssertNil(mag("100000000.01"))
    }

    // MARK: - Sign handling survives the new paths

    func testNegativesStillDetected() {
        XCTAssertEqual(AmountLexer.parseCell("(25,00)"), .init(magnitude: dec("25"), isNegative: true))
        XCTAssertEqual(AmountLexer.parseCell("-34839.699999999997"), .init(magnitude: dec("34839.70"), isNegative: true))
        XCTAssertEqual(AmountLexer.classify(numeric: dec("-42.5")), .value(.init(magnitude: dec("42.50"), isNegative: true)))
    }

    // MARK: - Numeric (xlsx-resolved) classification

    func testNumericClassification() {
        XCTAssertEqual(AmountLexer.classify(numeric: dec("34839.70")), .value(.init(magnitude: dec("34839.70"), isNegative: false)))
        XCTAssertEqual(AmountLexer.classify(numeric: 0), .none)
    }
}
