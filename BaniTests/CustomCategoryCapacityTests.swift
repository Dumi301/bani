import XCTest
import SwiftData
@testable import Bani

/// P5 decision 1 (spec §4.3.5) — custom-category capacity ≥16. The client needs
/// ≥12 real-estate customs; `SeededCustomCategory` ships 16. There is NO hard cap
/// on `CustomCategoryStore.create` — creation is unbounded, and the 8-swatch
/// color palette (`CustomCategoryPalette`) cycles safely past its bounds via a
/// modulo wrap. Categories beyond the 8th stay visually distinguishable because
/// every custom that reuses a cycled color is paired with a DISTINCT SF Symbol —
/// verified here against the actual 16 seeded customs, not just in the abstract.
/// The picker datasources (`CategoriesView`'s `List`, `CategoryChipPicker`'s
/// horizontal `ScrollView`) are plain `[CustomCategory]`-backed collections with
/// no fixed-size layout, so they scale to any count without a UI change.
@MainActor
final class CustomCategoryCapacityTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transaction.self, CategoryRule.self, CustomCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - No hard cap on creation

    func testCreatingBeyond16CategoriesIsNotCapped() throws {
        let context = try makeContext()
        var created: [CustomCategory] = []
        for i in 0..<20 {
            let symbol = CustomCategoryPalette.symbols[i % CustomCategoryPalette.symbols.count]
            let category = try XCTUnwrap(
                CustomCategoryStore.create(name: "Custom \(i)", symbolName: symbol, colorIndex: i, in: context),
                "creation must not be rejected past the old 8-slot ceiling"
            )
            created.append(category)
        }
        XCTAssertEqual(created.count, 20, "20 distinct custom categories created with zero rejections")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CustomCategory>()), 20)
    }

    // MARK: - Color cycling wraps safely past the 8-swatch palette

    func testColorIndexBeyond8WrapsToAValidSwatch() {
        for index in 0..<24 {
            let name = CustomCategoryPalette.colorName(index)
            XCTAssertTrue(CustomCategoryPalette.colorNames.contains(name), "index \(index) resolves to a real BaniCustom asset, never OOB")
            XCTAssertEqual(name, CustomCategoryPalette.colorName(index % 8), "the swatch cycles every 8 indices")
        }
        // Negative defensiveness (a stale/corrupted index) never crashes either.
        XCTAssertTrue(CustomCategoryPalette.colorNames.contains(CustomCategoryPalette.colorName(-3)))
    }

    // MARK: - The 16 seeded real-estate customs: distinct (color, symbol) pairs

    func testSeeded16CustomsHaveDistinctColorSymbolPairs() {
        let all = SeededCustomCategory.allCases
        XCTAssertGreaterThanOrEqual(all.count, 16, "the client needs >=12 real-estate customs; Bani ships >=16 seeded ones")

        // No two seeded customs share the exact same (cycled color, symbol) pair.
        var seenPairs = Set<String>()
        for token in all {
            let pairKey = "\(token.colorIndex)|\(token.symbolName)"
            XCTAssertTrue(seenPairs.insert(pairKey).inserted, "duplicate (color,symbol) pair for \(token.displayName)")
        }

        // The actual capacity mechanism: every pair of customs that land on the
        // SAME cycled swatch (8 apart in declaration order, since colorIndex =
        // order % 8) must carry a DIFFERENT symbol — that is what keeps 9...16+
        // categories visually distinguishable from 1...8 at a glance.
        let byColor = Dictionary(grouping: all, by: \.colorIndex)
        XCTAssertEqual(byColor.count, 8, "all 8 swatches are reused at least once past the 8th custom")
        for (colorIndex, group) in byColor {
            let symbols = Set(group.map(\.symbolName))
            XCTAssertEqual(symbols.count, group.count, "swatch \(colorIndex) is shared by \(group.count) customs that must use \(group.count) distinct symbols")
        }
    }

    // MARK: - Picker datasource handles 16+ (seeded + user-created) without breaking

    func testPickerDatasourceHandles16PlusCategories() throws {
        let context = try makeContext()
        // The 16 seeded real-estate customs, plus 4 more the user creates by hand.
        _ = PresetSeeding.ensureCustoms(in: context)
        for i in 0..<4 {
            _ = CustomCategoryStore.create(name: "Extra \(i)", symbolName: "star.fill", colorIndex: i, in: context)
        }
        let customs = CustomCategoryStore.all(in: context)
        XCTAssertGreaterThanOrEqual(customs.count, 20, "16 seeded + 4 user-created")

        // The exact datasource CategoryChipPicker / CategoriesView build their rows
        // from: presets + every custom, each resolving to a stable, non-crashing
        // style — the contract the pickers rely on at ANY count.
        let refs = TransactionCategory.allCases.map { CategoryRef.preset($0) }
            + customs.map { CategoryRef.custom($0.id) }
        XCTAssertEqual(refs.count, TransactionCategory.allCases.count + customs.count)

        let lookup = customs.lookup
        for custom in customs {
            let style = categoryStyle(.custom(custom.id), customs: lookup)
            XCTAssertEqual(style.label, custom.name)
            XCTAssertFalse(style.systemImage.isEmpty, "every entry resolves a real SF Symbol, never a blank chip")
        }

        // `ForEach(refs, id: \.id)` (CategoryChipPicker) needs unique ids at any
        // count — no collisions once past the old 8-category ceiling.
        XCTAssertEqual(Set(refs.map(\.id)).count, refs.count, "no id collisions across presets + 20 customs")
    }
}
