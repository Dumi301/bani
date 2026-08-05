import XCTest
@testable import Bani

/// Table-driven coverage of `RuleBasedParser` (forced explicitly by instantiating
/// the type directly — never goes through `FoundationModelsParser`). Each row
/// asserts amount, currency, AND that the description remainder retains the
/// expected keyword (robust to exact-string drift in the removed tokens).
final class ParserTests: XCTestCase {

    private struct Case {
        let name: String
        let input: String
        let expectedAmount: Decimal?
        let expectedCurrency: Currency
        let expectedKeyword: String?
    }

    private let cases: [Case] = [
        Case(
            name: "digits adjacent to 'de lei'",
            input: "50 de lei benzină",
            expectedAmount: Decimal(string: "50"),
            expectedCurrency: .ron,
            expectedKeyword: "benzină"
        ),
        Case(
            name: "RO spelled tens adjacent to 'de euro'",
            input: "douăzeci de euro taxi",
            expectedAmount: Decimal(string: "20"),
            expectedCurrency: .eur,
            expectedKeyword: "taxi"
        ),
        Case(
            name: "decimal comma",
            input: "12,50 lei cafea",
            expectedAmount: Decimal(string: "12.50"),
            expectedCurrency: .ron,
            expectedKeyword: "cafea"
        ),
        Case(
            name: "EN spelled hundred + tens ('a hundred fifty')",
            input: "a hundred fifty lei groceries",
            expectedAmount: Decimal(string: "150"),
            expectedCurrency: .ron,
            expectedKeyword: "groceries"
        ),
        Case(
            name: "RO spelled ones + sute ('cinci sute')",
            input: "cinci sute lei chirie",
            expectedAmount: Decimal(string: "500"),
            expectedCurrency: .ron,
            expectedKeyword: "chirie"
        ),
        Case(
            name: "digits adjacent to 'euro' (no 'de')",
            input: "20 euro parcare aeroport",
            expectedAmount: Decimal(string: "20"),
            expectedCurrency: .eur,
            expectedKeyword: "parcare"
        ),
        Case(
            name: "currency phrase after the spelled number, description before it",
            input: "taxi douăzeci de lei",
            expectedAmount: Decimal(string: "20"),
            expectedCurrency: .ron,
            expectedKeyword: "taxi"
        ),
        Case(
            name: "no amount present — never invent a number",
            input: "salut ce mai faci",
            expectedAmount: nil,
            expectedCurrency: .ron,
            expectedKeyword: "salut"
        ),
        Case(
            name: "two digit tokens — adjacency to currency wins over first token",
            input: "2 cafele 30 lei",
            expectedAmount: Decimal(string: "30"),
            expectedCurrency: .ron,
            expectedKeyword: "cafele"
        ),
        Case(
            name: "€ symbol",
            input: "35 € benzină",
            expectedAmount: Decimal(string: "35"),
            expectedCurrency: .eur,
            expectedKeyword: "benzină"
        ),
        Case(
            name: "decimal dot",
            input: "12.50 lei cafea",
            expectedAmount: Decimal(string: "12.50"),
            expectedCurrency: .ron,
            expectedKeyword: "cafea"
        ),

        // MARK: - B: large-amount parsing

        Case(
            name: "RO thousands dot — the reported bug (25.000 → 25000)",
            input: "25.000 lei chirie",
            expectedAmount: Decimal(string: "25000"),
            expectedCurrency: .ron,
            expectedKeyword: "chirie"
        ),
        Case(
            name: "EN thousands comma (25,000 → 25000)",
            input: "25,000 lei",
            expectedAmount: Decimal(string: "25000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "spaced thousands group (25 000 → 25000, kills adjacency-0 trap)",
            input: "25 000 de lei",
            expectedAmount: Decimal(string: "25000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "RO decimal with thousands dot (1.234,56 → 1234.56)",
            input: "1.234,56 lei",
            expectedAmount: Decimal(string: "1234.56"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "EN decimal with thousands comma (1,234.56 → 1234.56)",
            input: "1,234.56 euro",
            expectedAmount: Decimal(string: "1234.56"),
            expectedCurrency: .eur,
            expectedKeyword: nil
        ),
        Case(
            name: "decimal dot regression (12.5 → 12.5)",
            input: "12.5 euro",
            expectedAmount: Decimal(string: "12.5"),
            expectedCurrency: .eur,
            expectedKeyword: nil
        ),
        Case(
            name: "single thousands dot (1.000 → 1000)",
            input: "1.000 lei",
            expectedAmount: Decimal(string: "1000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "multiple thousands groups (1.234.567 → 1234567)",
            input: "1.234.567 lei",
            expectedAmount: Decimal(string: "1234567"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "RO spelled thousands (douăzeci și cinci de mii → 25000)",
            input: "douăzeci și cinci de mii de lei avans",
            expectedAmount: Decimal(string: "25000"),
            expectedCurrency: .ron,
            expectedKeyword: "avans"
        ),
        Case(
            name: "RO spelled 'o mie' (→ 1000)",
            input: "o mie de lei",
            expectedAmount: Decimal(string: "1000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "RO spelled millions (două milioane → 2000000)",
            input: "două milioane lei",
            expectedAmount: Decimal(string: "2000000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "hybrid digit + 'de mii' (25 de mii → 25000)",
            input: "25 de mii de lei",
            expectedAmount: Decimal(string: "25000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "hybrid decimal digit + millions (2,5 milioane → 2500000)",
            input: "2,5 milioane de lei",
            expectedAmount: Decimal(string: "2500000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "EN spelled thousands (twenty five thousand → 25000)",
            input: "twenty five thousand lei",
            expectedAmount: Decimal(string: "25000"),
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),
        Case(
            name: "EN spelled 'a million' (→ 1000000)",
            input: "a million euro",
            expectedAmount: Decimal(string: "1000000"),
            expectedCurrency: .eur,
            expectedKeyword: nil
        ),
        Case(
            name: "B4 guardrail — >100M rejected (nil amount, stays in edit mode)",
            input: "200000000 lei",
            expectedAmount: nil,
            expectedCurrency: .ron,
            expectedKeyword: nil
        ),

        // MARK: - Bug B: float-dust / long-decimal tails round to money (shared
        // `value(forDigitToken)` change — the voice path inherits it too). Replaces
        // the old digit-concatenation behavior (would have read "12.3456" → 123456).

        Case(
            name: "long decimal tail rounds to 2dp (12.3456 → 12.35)",
            input: "12.3456 lei ceva",
            expectedAmount: Decimal(string: "12.35"),
            expectedCurrency: .ron,
            expectedKeyword: "ceva"
        ),
        Case(
            name: "float-dust tail rounds to 2dp (1149.8500000000001 → 1149.85)",
            input: "1149.8500000000001 lei taxa",
            expectedAmount: Decimal(string: "1149.85"),
            expectedCurrency: .ron,
            expectedKeyword: "taxa"
        )
    ]

    func testRuleBasedParserTableDrivenCases() async {
        let parser = RuleBasedParser()

        for testCase in cases {
            let result = await parser.parse(testCase.input)

            XCTAssertEqual(
                result.amount, testCase.expectedAmount,
                "amount mismatch for '\(testCase.name)' (input: \(testCase.input))"
            )
            XCTAssertEqual(
                result.currency, testCase.expectedCurrency,
                "currency mismatch for '\(testCase.name)' (input: \(testCase.input))"
            )
            if let keyword = testCase.expectedKeyword {
                XCTAssertTrue(
                    result.descriptionText.localizedCaseInsensitiveContains(keyword),
                    "description '\(result.descriptionText)' missing keyword '\(keyword)' for '\(testCase.name)'"
                )
            }
        }
    }

    func testNoAmountTranscriptOpensEditModeWithNilAmount() async {
        let parser = RuleBasedParser()
        let result = await parser.parse("salut ce mai faci")
        XCTAssertNil(result.amount)
        XCTAssertEqual(result.currency, .ron)
    }
}
