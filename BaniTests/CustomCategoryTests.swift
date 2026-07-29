import XCTest
import SwiftData
@testable import Bani

/// C5 — custom-category round-trips: create → assign → persist, duplicate-name
/// rejection, delete-with-reassignment (transactions AND rules move, never
/// orphaned), the learning loop with a custom target, and chart aggregation.
@MainActor
final class CustomCategoryTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transaction.self, CategoryRule.self, CustomCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Create / assign / persist

    func testCreateAssignPersistRoundTrip() throws {
        let context = try makeContext()
        let sport = try XCTUnwrap(CustomCategoryStore.create(name: "Sport", symbolName: "figure.run", colorIndex: 3, in: context))

        let tx = Transaction(amount: 40, currency: .ron, context: .personal, descriptionText: "padel", source: .manual)
        tx.categoryRef = .custom(sport.id)
        context.insert(tx)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.customCategoryID, sport.id)
        XCTAssertEqual(fetched.first?.categoryRef, .custom(sport.id))
        XCTAssertNil(fetched.first?.category, "a custom assignment clears the preset enum (single identity source)")
    }

    // MARK: - Duplicate rejection

    func testDuplicateNameRejectedNormalizedInsensitive() throws {
        let context = try makeContext()
        XCTAssertNotNil(CustomCategoryStore.create(name: "Sport", symbolName: "star.fill", colorIndex: 0, in: context))
        // Different case, diacritics and surrounding whitespace still collide.
        XCTAssertNil(CustomCategoryStore.create(name: "  spórt ", symbolName: "star.fill", colorIndex: 1, in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CustomCategory>()), 1)
    }

    func testRenameToExistingNameRejected_ButToOwnNameAllowed() throws {
        let context = try makeContext()
        let a = try XCTUnwrap(CustomCategoryStore.create(name: "Sport", symbolName: "star.fill", colorIndex: 0, in: context))
        _ = try XCTUnwrap(CustomCategoryStore.create(name: "Travel", symbolName: "airplane", colorIndex: 1, in: context))

        XCTAssertFalse(CustomCategoryStore.update(a, name: "Travel", symbolName: "star.fill", colorIndex: 0, in: context),
                       "renaming onto another category's name is rejected")
        XCTAssertTrue(CustomCategoryStore.update(a, name: "Sport", symbolName: "trophy.fill", colorIndex: 2, in: context),
                      "keeping its own name (restyling) is allowed")
        XCTAssertEqual(a.colorIndex, 2)
    }

    // MARK: - Delete with reassignment

    func testDeleteReassignsTransactionsAndRules() throws {
        let context = try makeContext()
        let sport = try XCTUnwrap(CustomCategoryStore.create(name: "Sport", symbolName: "figure.run", colorIndex: 2, in: context))

        let tx = Transaction(amount: 40, currency: .ron, context: .personal, descriptionText: "padel", source: .manual)
        tx.categoryRef = .custom(sport.id)
        context.insert(tx)
        // A learned rule pointing at the custom category.
        CategoryRuleStore.learn(correctedRef: .custom(sport.id), description: "padel", in: context)
        try context.save()
        XCTAssertEqual(CustomCategoryStore.transactionCount(for: sport.id, in: context), 1)

        CustomCategoryStore.delete(sport, reassignTo: .preset(.entertainment), in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CustomCategory>()), 0, "the category is gone")
        let moved = try XCTUnwrap(try context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertNil(moved.customCategoryID, "the transaction is never orphaned")
        XCTAssertEqual(moved.categoryRef, .preset(.entertainment))
        // The learned rule moved too — the keyword now resolves to the new target.
        XCTAssertEqual(CategoryRuleStore.guessRef(description: "padel", in: context), .preset(.entertainment))
    }

    // MARK: - Learning loop

    func testLearningRoundTripWithCustomCategory() throws {
        let context = try makeContext()
        CategoryRuleStore.seedIfNeeded(context)
        let sport = try XCTUnwrap(CustomCategoryStore.create(name: "Sport", symbolName: "figure.run", colorIndex: 4, in: context))

        // Unknown keyword → Other before learning.
        XCTAssertEqual(CategoryRuleStore.guessRef(description: "padel la club", in: context), .preset(.other))

        // Correcting to the custom category teaches the salient keyword.
        CategoryRuleStore.learn(correctedRef: .custom(sport.id), description: "padel la club", in: context)

        XCTAssertEqual(CategoryRuleStore.guessRef(description: "padel la club", in: context), .custom(sport.id))
        XCTAssertEqual(CategoryRuleStore.guessRef(description: "am jucat padel", in: context), .custom(sport.id),
                       "another utterance carrying the same keyword resolves to the custom category")
    }

    // MARK: - Chart aggregation

    func testChartsAggregateCustomCategoryAsItsOwnBucket() {
        let id1 = UUID(); let id2 = UUID()
        let items = [
            SpendItem(amount: 30, currency: .ron, customCategoryID: id1, date: Date()),
            SpendItem(amount: 20, currency: .ron, customCategoryID: id1, date: Date()),
            SpendItem(amount: 10, currency: .ron, category: .fuel, date: Date()),
            SpendItem(amount: 5, currency: .ron, customCategoryID: id2, date: Date()),
        ]
        let totals = FinancesAnalytics.byCategory(items, rate: nil)
        XCTAssertEqual(totals.count, 3, "custom id1, custom id2 and preset fuel are three distinct buckets")
        XCTAssertEqual(totals.first { $0.categoryRef == .custom(id1) }?.total, 30 + 20)
        XCTAssertEqual(totals.first { $0.categoryRef == .custom(id1) }?.count, 2)
        XCTAssertEqual(totals.first { $0.categoryRef == .custom(id2) }?.total, 5)
        XCTAssertEqual(totals.first { $0.categoryRef == .preset(.fuel) }?.total, 10)
        XCTAssertEqual(totals.first?.categoryRef, .custom(id1), "highest total (50) sorts first")
    }
}
