import SwiftUI

/// Per-category semantic colors for the analytics donut, bars, and breakdown
/// rows (D2). Each maps to an asset-catalog colorset with an Any + Dark
/// appearance, derived from the warm minimalist palette (kept desaturated so
/// nine hues still read as one family).
extension TransactionCategory {
    var colorName: String {
        switch self {
        case .fuel: "BaniCatFuel"
        case .groceries: "BaniCatGroceries"
        case .dining: "BaniCatDining"
        case .transport: "BaniCatTransport"
        case .utilities: "BaniCatUtilities"
        case .shopping: "BaniCatShopping"
        case .health: "BaniCatHealth"
        case .entertainment: "BaniCatEntertainment"
        case .other: "BaniCatOther"
        }
    }

    var color: Color { Color(colorName) }
}

/// Color for an optional category — `nil` (uncategorized) falls back to the
/// neutral secondary ink so the donut / breakdown always has a stable color.
func categoryColor(_ category: TransactionCategory?) -> Color {
    category?.color ?? Color("BaniSecondaryInk")
}

// MARK: - CategoryRef resolution (presets + custom categories)

/// The resolved display attributes for a `CategoryRef?` — the single place a
/// preset or a custom category (or uncategorized) turns into a label, an SF
/// Symbol, and a semantic color. Custom refs resolve through the `customs`
/// lookup; an orphaned custom id (never expected — deletes always reassign)
/// degrades to the neutral uncategorized style rather than crashing.
struct CategoryStyle: Equatable {
    var label: String
    var systemImage: String
    var color: Color
}

func categoryStyle(_ ref: CategoryRef?, customs: CustomCategoryLookup) -> CategoryStyle {
    let uncategorized = CategoryStyle(
        label: String(localized: "category.uncategorized"),
        systemImage: "square.grid.2x2.fill",
        color: Color("BaniSecondaryInk")
    )
    guard let ref else { return uncategorized }
    switch ref {
    case .preset(let category):
        return CategoryStyle(label: category.label, systemImage: category.systemImage, color: category.color)
    case .custom(let id):
        guard let snap = customs[id] else { return uncategorized }
        return CategoryStyle(
            label: snap.name,
            systemImage: snap.symbolName,
            color: CustomCategoryPalette.color(snap.colorIndex)
        )
    }
}

/// Convenience color-only resolver for a `CategoryRef?`.
func categoryColor(_ ref: CategoryRef?, customs: CustomCategoryLookup) -> Color {
    categoryStyle(ref, customs: customs).color
}
