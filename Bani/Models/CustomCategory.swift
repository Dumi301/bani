import Foundation
import SwiftData

/// A user-defined spending category, born from "Other" (C1). A NEW, separate
/// SwiftData entity — the frozen `Transaction` model is untouched except for the
/// single sanctioned optional `customCategoryID` field. Adding this entity to the
/// container is a lightweight, additive migration; existing rows are untouched.
///
/// - `name` is stored verbatim (user's casing/diacritics); duplicate detection and
///   search fold it via `Categorizer.normalize`.
/// - `symbolName` is an SF Symbol from the curated grid (`CustomCategoryPalette`).
/// - `colorIndex` indexes the fixed 8-swatch palette (`BaniCustom0…7`).
@Model
final class CustomCategory {
    var id: UUID
    var name: String
    var symbolName: String
    var colorIndex: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String,
        colorIndex: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }
}

/// A value-type snapshot of one `CustomCategory`, so views and pure logic can
/// resolve a `CategoryRef.custom` to its display attributes without a live
/// `ModelContext` — mirrors `CategoryRuleSnapshot`.
struct CustomCategorySnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let symbolName: String
    let colorIndex: Int
}

extension CustomCategory {
    var snapshot: CustomCategorySnapshot {
        CustomCategorySnapshot(id: id, name: name, symbolName: symbolName, colorIndex: colorIndex)
    }
}

/// A lookup from custom-category id → snapshot, built once per render from a
/// `@Query` and threaded to the resolvers (`categoryStyle`, search, grouping).
typealias CustomCategoryLookup = [UUID: CustomCategorySnapshot]

extension Array where Element == CustomCategory {
    /// Builds the id → snapshot lookup for the resolver helpers.
    var lookup: CustomCategoryLookup {
        var out: CustomCategoryLookup = [:]
        for category in self { out[category.id] = category.snapshot }
        return out
    }
}
