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
