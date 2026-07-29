import XCTest
import SwiftData
@testable import Bani

/// SwiftData-backed coverage of `CategoryRuleStore` — the learning seam.
/// Proves the round trip the C4/C5 contract requires: seed → guess → user
/// correction → the SAME keyword auto-categorizes on the next save.
@MainActor
final class CategoryRuleStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transaction.self, CategoryRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testSeedIfNeededIsIdempotent() throws {
        let context = try makeContext()
        CategoryRuleStore.seedIfNeeded(context)
        let firstCount = try context.fetchCount(FetchDescriptor<CategoryRule>())
        XCTAssertEqual(firstCount, CategorySeeds.table.count)

        CategoryRuleStore.seedIfNeeded(context)
        let secondCount = try context.fetchCount(FetchDescriptor<CategoryRule>())
        XCTAssertEqual(secondCount, firstCount, "re-seeding must not duplicate rules")
    }

    func testSeededGuessUsesTheTable() throws {
        let context = try makeContext()
        CategoryRuleStore.seedIfNeeded(context)
        XCTAssertEqual(CategoryRuleStore.guess(description: "benzină", in: context), .fuel)
        XCTAssertEqual(CategoryRuleStore.guess(description: "ceva necunoscut", in: context), .other)
    }

    /// The C4/C6 round trip: correcting a category teaches a keyword so the next
    /// identical description auto-categorizes to the corrected value.
    func testCorrectionIsLearnedAndReappliesToTheSameKeyword() throws {
        let context = try makeContext()
        CategoryRuleStore.seedIfNeeded(context)

        // A word with no seed → Other before learning.
        XCTAssertEqual(CategoryRuleStore.guess(description: "spălătorie auto", in: context), .other)

        // User corrects it to transport. Salient keyword = "spalatorie".
        CategoryRuleStore.learn(correctedCategory: .transport, description: "spălătorie auto", in: context)

        // Same description now auto-categorizes to the learned value...
        XCTAssertEqual(CategoryRuleStore.guess(description: "spălătorie auto", in: context), .transport)
        // ...and so does another utterance carrying the same salient keyword.
        XCTAssertEqual(CategoryRuleStore.guess(description: "am fost la spălătorie", in: context), .transport)
    }

    func testLearnedRuleOverridesASeed() throws {
        let context = try makeContext()
        CategoryRuleStore.seedIfNeeded(context)

        // "starbucks" ships as a dining seed.
        XCTAssertEqual(CategoryRuleStore.guess(description: "cafea la starbucks", in: context), .dining)

        // User insists it's entertainment. Salient keyword = "starbucks".
        CategoryRuleStore.learn(correctedCategory: .entertainment, description: "cafea la starbucks", in: context)

        XCTAssertEqual(CategoryRuleStore.guess(description: "cafea la starbucks", in: context), .entertainment,
                       "the learned rule must beat the dining seed")
    }

    func testReinforceIncrementsHitCount() throws {
        let context = try makeContext()
        CategoryRuleStore.seedIfNeeded(context)

        let match = try XCTUnwrap(CategoryRuleStore.bestMatch(description: "benzină", in: context))
        XCTAssertEqual(match.keyword, "benzina")

        CategoryRuleStore.reinforce(keyword: match.keyword, origin: match.origin, in: context)

        let after = try XCTUnwrap(CategoryRuleStore.bestMatch(description: "benzină", in: context))
        XCTAssertEqual(after.hitCount, match.hitCount + 1)
    }
}
