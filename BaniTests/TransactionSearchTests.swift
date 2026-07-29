import XCTest
@testable import Bani

/// C — deterministic, diacritic- and case-insensitive search: folded description
/// match, category match by label AND keyword, free-token (person/merchant)
/// match, learned-keyword match, and per-currency totals correctness.
final class TransactionSearchTests: XCTestCase {

    private func fields(_ description: String, raw: String? = nil, merchant: String? = nil, category: TransactionCategory? = nil) -> TransactionSearch.Fields {
        TransactionSearch.Fields(descriptionText: description, rawTranscript: raw, merchant: merchant, category: category)
    }

    private func matches(_ f: TransactionSearch.Fields, _ query: String, learned: [CategoryRuleSnapshot] = []) -> Bool {
        let q = TransactionSearch.fold(query)
        let categories = TransactionSearch.categoriesMatching(foldedQuery: q, learnedRules: learned)
        return TransactionSearch.matches(f, foldedQuery: q, matchingCategories: categories)
    }

    func testDiacriticFoldedMatch() {
        // "branșament" is found by the un-accented "bransament".
        XCTAssertTrue(matches(fields("branșament electric"), "bransament"))
        XCTAssertTrue(matches(fields("plin de benzină"), "benzina"))
    }

    func testCategoryLabelAndKeywordMatch() {
        let fuel = fields("plin", merchant: "OMV", category: .fuel)
        XCTAssertTrue(matches(fuel, "fuel"), "category label should match")
        XCTAssertTrue(matches(fuel, "benzina"), "a seed keyword should resolve to its category")
    }

    func testPersonAndMerchantNameMatch() {
        XCTAssertTrue(matches(fields("cadou pentru Andrei"), "andrei"))
        XCTAssertTrue(matches(fields("masă", raw: "am plătit masa cu Maria"), "maria"))
        XCTAssertTrue(matches(fields("cursă", merchant: "Bolt"), "bolt"))
    }

    func testLearnedKeywordResolvesCategory() {
        let learned = [CategoryRuleSnapshot(keyword: "padel", category: .entertainment, origin: .learned, hitCount: 1)]
        let tx = fields("teren", category: .entertainment)
        XCTAssertTrue(matches(tx, "padel", learned: learned))
    }

    func testNoMatch() {
        XCTAssertFalse(matches(fields("cafea", category: .dining), "benzina"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(matches(fields("anything at all"), ""))
    }

    func testPerCurrencyTotalsCorrectness() {
        // Totals over a (searched) result set stay Decimal-exact.
        let results = [
            SpendItem(amount: Decimal(string: "10.50")!, currency: .ron, category: .fuel, date: Date()),
            SpendItem(amount: 5, currency: .ron, category: .dining, date: Date()),
            SpendItem(amount: 3, currency: .eur, category: .dining, date: Date()),
        ]
        let byCurrency = FinancesAnalytics.totalsByCurrency(results)
        XCTAssertEqual(byCurrency[.ron], Decimal(string: "15.50"))
        XCTAssertEqual(byCurrency[.eur], 3)
    }
}
