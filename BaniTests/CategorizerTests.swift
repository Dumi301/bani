import XCTest
@testable import Bani

/// Pure-logic coverage of `Categorizer` — no SwiftData, no `ModelContext`.
/// Uses value-type `CategoryRuleSnapshot`s so the matching precedence is
/// asserted directly: seed RO+EN incl. diacritics, learned-beats-seed,
/// longest-keyword-wins, and no-match → `.other`.
final class CategorizerTests: XCTestCase {

    private func seed(_ keyword: String, _ category: TransactionCategory, hits: Int = 0) -> CategoryRuleSnapshot {
        CategoryRuleSnapshot(keyword: keyword, category: category, origin: .seed, hitCount: hits)
    }
    private func learned(_ keyword: String, _ category: TransactionCategory, hits: Int = 0) -> CategoryRuleSnapshot {
        CategoryRuleSnapshot(keyword: keyword, category: category, origin: .learned, hitCount: hits)
    }

    /// The shipped seed table, as snapshots — mirrors what the store loads.
    private var seedSnapshots: [CategoryRuleSnapshot] {
        CategorySeeds.table.map { seed($0.keyword, $0.category) }
    }

    // MARK: - Seeds match, RO + EN + diacritics

    func testRomanianSeedWithDiacriticsMatches() {
        // "benzină" (diacritics) must fold to the stored "benzina" seed.
        XCTAssertEqual(Categorizer.category(for: "benzină", rules: seedSnapshots), .fuel)
        XCTAssertEqual(Categorizer.category(for: "cumpărături la piață", rules: seedSnapshots), .groceries)
        XCTAssertEqual(Categorizer.category(for: "factură curent", rules: seedSnapshots), .utilities)
    }

    func testEnglishSeedMatches() {
        XCTAssertEqual(Categorizer.category(for: "coffee with a friend", rules: seedSnapshots), .dining)
        XCTAssertEqual(Categorizer.category(for: "monthly groceries", rules: seedSnapshots), .groceries)
        XCTAssertEqual(Categorizer.category(for: "uber ride home", rules: seedSnapshots), .transport)
    }

    func testMerchantBrandSeedsMatch() {
        XCTAssertEqual(Categorizer.category(for: "plin la OMV", rules: seedSnapshots), .fuel)
        XCTAssertEqual(Categorizer.category(for: "cumpărături Lidl", rules: seedSnapshots), .groceries)
        XCTAssertEqual(Categorizer.category(for: "abonament Netflix", rules: seedSnapshots), .entertainment)
    }

    // MARK: - No match → Other (chip never empty)

    func testNoMatchReturnsOther() {
        XCTAssertEqual(Categorizer.category(for: "ceva ciudat necategorisit", rules: seedSnapshots), .other)
        XCTAssertNil(Categorizer.bestMatch(for: "ceva ciudat necategorisit", rules: seedSnapshots))
    }

    func testEmptyTextReturnsOther() {
        XCTAssertEqual(Categorizer.category(for: "", rules: seedSnapshots), .other)
    }

    // MARK: - Learned beats seed on conflict

    func testLearnedBeatsSeedOnSameKeyword() {
        let rules = [seed("taxi", .transport), learned("taxi", .shopping)]
        XCTAssertEqual(Categorizer.category(for: "taxi", rules: rules), .shopping,
                       "a learned rule must win over a seed for the same keyword")
    }

    func testLearnedBeatsSeedEvenWhenSeedKeywordIsLonger() {
        // Precedence rule 1 (learned over seed) outranks rule 2 (longest keyword):
        // a short learned keyword still beats a longer seed keyword.
        let rules = [seed("restaurant", .dining), learned("pizza", .entertainment)]
        XCTAssertEqual(Categorizer.category(for: "pizza la restaurant", rules: rules), .entertainment)
    }

    // MARK: - Longest keyword wins within a tier

    func testLongestKeywordWinsAmongSeeds() {
        let rules = [seed("cafea", .dining), seed("starbucks", .shopping)]
        // Both match "cafea la starbucks"; the longer keyword ("starbucks") wins.
        XCTAssertEqual(Categorizer.category(for: "cafea la starbucks", rules: rules), .shopping)
    }

    func testHitCountBreaksLengthTie() {
        let rules = [learned("aaaa", .dining, hits: 1), learned("bbbb", .health, hits: 9)]
        XCTAssertEqual(Categorizer.category(for: "aaaa bbbb", rules: rules), .health,
                       "equal-length learned rules break the tie on hitCount")
    }

    // MARK: - Salient keyword extraction (what a correction is learned under)

    func testSalientKeywordPicksLongestNonCurrencyToken() {
        // The headline example from the run brief.
        XCTAssertEqual(Categorizer.salientKeyword(in: "cafea la Starbucks"), "starbucks")
    }

    func testSalientKeywordSkipsNumbersAndCurrencyWords() {
        XCTAssertEqual(Categorizer.salientKeyword(in: "50 lei benzina"), "benzina")
    }

    func testSalientKeywordFallsBackToFullTextWhenOnlyNumbers() {
        // No non-numeric/non-currency token → the full normalized text.
        XCTAssertEqual(Categorizer.salientKeyword(in: "50 lei"), "50 lei")
    }
}
