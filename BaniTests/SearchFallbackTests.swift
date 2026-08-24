import XCTest
import Foundation
@testable import Bani

/// P11 gate — the fallback law: when Foundation Models is unavailable (or a
/// proposal has nothing usable), the smart search's output over any query is
/// BYTE-IDENTICAL to calling the existing keyword search (`TransactionSearch`)
/// directly on that same query — never a second search implementation, never a
/// user-visible behavior change. Mirrors `InterpretationServiceTests`'
/// `testFallbackIsByteIdenticalToDeterministicPipeline` for the search seam.
final class SearchFallbackTests: XCTestCase {

    // MARK: - Corpus (RO + EN, diacritics, category keywords, merchant, counterparty)

    private let corpus: [SmartSearchService.Item] = [
        SmartSearchService.Item(id: UUID(), amount: 50, currency: .ron, direction: .expense,
                                 date: Date(timeIntervalSince1970: 5_000), categoryRef: .preset(.fuel),
                                 descriptionText: "plin de benzină", merchant: "OMV"),
        SmartSearchService.Item(id: UUID(), amount: 1200, currency: .ron, direction: .expense,
                                 date: Date(timeIntervalSince1970: 4_000), categoryRef: .preset(.utilities),
                                 counterparty: "Enel", descriptionText: "factura curent"),
        SmartSearchService.Item(id: UUID(), amount: 300, currency: .eur, direction: .expense,
                                 date: Date(timeIntervalSince1970: 3_000), categoryRef: .preset(.dining),
                                 descriptionText: "cină cu Maria", rawTranscript: "am platit masa cu Maria"),
        SmartSearchService.Item(id: UUID(), amount: 25, currency: .ron, direction: .expense,
                                 date: Date(timeIntervalSince1970: 2_000), categoryRef: .preset(.transport),
                                 descriptionText: "cursă", merchant: "Bolt"),
        SmartSearchService.Item(id: UUID(), amount: 2000, currency: .ron, direction: .income,
                                 date: Date(timeIntervalSince1970: 1_000), categoryRef: nil,
                                 descriptionText: "salariu"),
        SmartSearchService.Item(id: UUID(), amount: 15, currency: .ron, direction: .expense,
                                 date: Date(timeIntervalSince1970: 6_000), categoryRef: .preset(.dining),
                                 descriptionText: "cafea", merchant: "Starbucks"),
    ]

    private let queries = [
        "bransament", "benzina", "fuel", "enel", "maria", "bolt",
        "salariu", "cafea", "nimic-de-gasit-aici", "", "  ",
    ]

    /// The existing keyword search, called EXACTLY the way every production
    /// call site (`FinancesView.applySearch`) calls it — the golden baseline.
    private func existingKeywordSearch(_ query: String, items: [SmartSearchService.Item]) -> [SmartSearchService.Item] {
        let q = TransactionSearch.fold(query)
        guard !q.isEmpty else { return items }
        let categories = TransactionSearch.categoriesMatching(foldedQuery: q, learnedRules: [])
        return items.filter { item in
            TransactionSearch.matches(
                TransactionSearch.Fields(
                    descriptionText: item.descriptionText, rawTranscript: item.rawTranscript,
                    merchant: item.merchant, counterparty: item.counterparty,
                    category: item.categoryRef?.presetValue, customCategoryID: item.categoryRef?.customID
                ),
                foldedQuery: q, matchingCategories: categories, matchingCustoms: []
            )
        }
    }

    // MARK: - Golden assertion (FM unavailable)

    func testFallbackIsByteIdenticalToExistingKeywordSearchAcrossCorpus() async {
        for query in queries {
            let outcome = await SmartSearchService.search(
                query: query, now: Date(), calendar: .current, items: corpus,
                projects: [], people: [], compiler: UnavailableQueryCompiler()
            )
            let expected = existingKeywordSearch(query, items: corpus)
            XCTAssertNil(outcome.filter, "query '\(query)': no structured filter — FM is unavailable")
            XCTAssertEqual(outcome.results, expected, "query '\(query)': fallback must be byte-identical to the existing keyword search")
        }
    }

    // MARK: - Golden assertion (FM available but proposes nothing usable)

    private struct EmptyProposalCompiler: QueryCompiling {
        var isAvailable: Bool { true }
        func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal? { SearchQueryProposal.none }
    }

    func testFallbackIsByteIdenticalWhenCompilerProposesNothingUsable() async {
        for query in queries {
            let outcome = await SmartSearchService.search(
                query: query, now: Date(), calendar: .current, items: corpus,
                projects: [], people: [], compiler: EmptyProposalCompiler()
            )
            let expected = existingKeywordSearch(query, items: corpus)
            XCTAssertNil(outcome.filter, "query '\(query)': an empty proposal is the same fallback marker")
            XCTAssertEqual(outcome.results, expected)
        }
    }

    // MARK: - Golden assertion (a hung compiler times out ⇒ same fallback)

    private struct HungCompiler: QueryCompiling {
        var isAvailable: Bool { true }
        func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal? {
            try? await Task.sleep(for: .seconds(10))
            return SearchQueryProposal(presetCategory: .fuel)
        }
    }

    func testFallbackIsByteIdenticalWhenCompilerTimesOut() async {
        let query = "benzina"
        let outcome = await SmartSearchService.search(
            query: query, now: Date(), calendar: .current, items: corpus,
            projects: [], people: [], compiler: HungCompiler(), timeout: .milliseconds(20)
        )
        let expected = existingKeywordSearch(query, items: corpus)
        XCTAssertNil(outcome.filter)
        XCTAssertEqual(outcome.results, expected)
    }

    // MARK: - Diacritic folding survives the fallback path unchanged

    func testDiacriticFoldedFallbackMatch() async {
        let outcome = await SmartSearchService.search(
            query: "benzina", now: Date(), calendar: .current, items: corpus,
            projects: [], people: [], compiler: UnavailableQueryCompiler()
        )
        XCTAssertEqual(outcome.results.map(\.descriptionText), ["plin de benzină"])
    }
}
