import XCTest
@testable import Bani

/// Category-column value matching against preset display names (RO + EN) + custom
/// categories, plus the unmatched-values collection that drives the match screen.
final class CategoryMatcherTests: XCTestCase {

    func testMatchesPresetsRomanianAndEnglish() {
        let m = CategoryMatcher(customCategories: [])
        XCTAssertEqual(m.match("Alimente"), .preset(.groceries))
        XCTAssertEqual(m.match("Groceries"), .preset(.groceries))
        XCTAssertEqual(m.match("Combustibil"), .preset(.fuel))
        XCTAssertEqual(m.match("Fuel"), .preset(.fuel))
        XCTAssertEqual(m.match("Restaurant"), .preset(.dining))
        XCTAssertEqual(m.match("Utilitati"), .preset(.utilities))
        XCTAssertEqual(m.match("Sănătate"), .preset(.health))   // diacritic-folded
    }

    func testMatchesEnumRawValue() {
        let m = CategoryMatcher(customCategories: [])
        XCTAssertEqual(m.match("entertainment"), .preset(.entertainment))
    }

    func testMatchesCustomCategory() {
        let id = UUID()
        let custom = CustomCategorySnapshot(id: id, name: "Donații", symbolName: "gift.fill", colorIndex: 1)
        let m = CategoryMatcher(customCategories: [custom])
        XCTAssertEqual(m.match("donatii"), .custom(id))   // folded + lowercased
        XCTAssertEqual(m.match("Donații"), .custom(id))
    }

    func testUnmatchedReturnsNil() {
        let m = CategoryMatcher(customCategories: [])
        XCTAssertNil(m.match("Ceva ciudat"))
        XCTAssertNil(m.match(""))
    }

    func testUnmatchedValuesDistinctFirstAppearance() {
        let m = CategoryMatcher(customCategories: [])
        let values = ["Alimente", "Ceva ciudat", "Fuel", "ceva ciudat", "Alt necunoscut", ""]
        XCTAssertEqual(m.unmatchedValues(in: values), ["Ceva ciudat", "Alt necunoscut"])
    }
}
