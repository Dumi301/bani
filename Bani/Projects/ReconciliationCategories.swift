import Foundation
import SwiftData

/// The reconciliation-adjustment category seam (v2). A closing adjustment (the
/// transaction that reconciles a drift between logged flows and the client's real
/// balance) is tagged with a single, stable custom-category id so it reads as
/// "Balance adjustment" in Finances and is trivially auditable / filterable. This
/// file OWNS the constant and its (idempotent) seeding; it deliberately does NOT
/// touch the `Categorization/` files — it only inserts one `CustomCategory` row
/// with a fixed id via a `ModelContext`, using the sanctioned
/// `Transaction.customCategoryID` seam (which takes precedence over the frozen
/// `category` enum — see `Transaction.categoryRef`).
///
/// Why a `CustomCategory` and not a new `TransactionCategory` case: the preset
/// `TransactionCategory` enum is a FROZEN seam; adding a case is out of bounds. The
/// `customCategoryID` pointer is the one approved extension point (same precedent as
/// `LoanCategories.interestCategoryID`), so the adjustment label lives there — no
/// frozen-enum edit, no migration risk.
enum ReconciliationCategories {

    /// The fixed id of the seeded "Balance adjustment" custom category. A
    /// compile-time constant so an adjustment can be tagged without a lookup and so
    /// the row is unique/idempotent across launches. Chosen well outside any user-
    /// or sibling-minted id space, and distinct from `LoanCategories.interestCategoryID`.
    static let adjustmentCategoryID = UUID(uuidString: "0000AD1F-0000-4000-8000-000000000001")!

    /// The seeded category's SF Symbol (from the curated grid) and palette index.
    static let adjustmentSymbolName = "equal.circle"
    static let adjustmentColorIndex = 5

    /// The verbatim name stored on the seeded `CustomCategory` (ro + en resolve at
    /// render time via `String(localized:)`, but the stored name is a stable key).
    static var adjustmentCategoryName: String { String(localized: "reconcile.category.adjustment") }

    /// Idempotently ensure the "Balance adjustment" custom category row exists, so
    /// the tag resolves to a real name/color in the UI. Safe to call repeatedly and
    /// concurrently with any other seeding: it keys on the fixed id and inserts only
    /// when absent. Never mutates an existing row (respects a user rename).
    @MainActor
    static func seedAdjustmentCategory(in modelContext: ModelContext) {
        let targetID = adjustmentCategoryID
        let descriptor = FetchDescriptor<CustomCategory>(predicate: #Predicate { $0.id == targetID })
        let existing = (try? modelContext.fetch(descriptor))?.first
        guard existing == nil else { return }
        modelContext.insert(CustomCategory(
            id: targetID,
            name: adjustmentCategoryName,
            symbolName: adjustmentSymbolName,
            colorIndex: adjustmentColorIndex
        ))
    }
}
