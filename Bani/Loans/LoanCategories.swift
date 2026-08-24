import Foundation
import SwiftData

/// The loan-interest category seam (v1.2b). Interest slices of loan payments —
/// bank AND investor — are tagged with a single, stable custom-category id so
/// they read as "Loan interest" in Finances and the report. This file OWNS the
/// constant and its (idempotent) seeding; it deliberately does NOT touch the P5
/// worker's `Categorization/` files — it only inserts one `CustomCategory` row
/// with a fixed id via a `ModelContext`, using the sanctioned
/// `Transaction.customCategoryID` seam (which takes precedence over the frozen
/// `category` enum — see `Transaction.categoryRef`).
///
/// Why a `CustomCategory` and not a new `TransactionCategory` case: the preset
/// `TransactionCategory` enum is a FROZEN seam; adding a case is out of bounds.
/// The `customCategoryID` pointer is the one approved extension point, so the
/// loan-interest label lives there — no frozen-enum edit, no migration risk.
///
/// The bank vs investor distinction is NOT carried by the category (both use the
/// same "Loan interest" label). It is carried by `Transaction.projectID` (bank =
/// the loan's project; investor = `nil`) and recovered via `loanID → Loan.kind`.
enum LoanCategories {

    /// The fixed id of the seeded "Loan interest" custom category. A compile-time
    /// constant so the interest transaction can be tagged without a lookup and so
    /// the row is unique/idempotent across launches. Chosen well outside any
    /// user- or P5-minted id space.
    static let interestCategoryID = UUID(uuidString: "0000A15E-0000-4000-8000-000000000001")!

    /// The seeded category's SF Symbol (from the curated grid) and palette index.
    static let interestSymbolName = "percent"
    static let interestColorIndex = 6

    /// The verbatim name stored on the seeded `CustomCategory` (ro + en resolve at
    /// render time via `String(localized:)`, but the stored name is a stable key).
    static var interestCategoryName: String { String(localized: "loan.category.interest") }

    /// Idempotently ensure the "Loan interest" custom category row exists, so the
    /// tag resolves to a real name/color in the UI. Safe to call repeatedly and
    /// concurrently with any other seeding: it keys on the fixed id and inserts
    /// only when absent. Never mutates an existing row (respects a user rename).
    @MainActor
    static func seedInterestCategory(in modelContext: ModelContext) {
        let targetID = interestCategoryID
        let descriptor = FetchDescriptor<CustomCategory>(predicate: #Predicate { $0.id == targetID })
        let existing = (try? modelContext.fetch(descriptor))?.first
        guard existing == nil else { return }
        modelContext.insert(CustomCategory(
            id: targetID,
            name: interestCategoryName,
            symbolName: interestSymbolName,
            colorIndex: interestColorIndex
        ))
    }
}
