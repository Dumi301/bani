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
