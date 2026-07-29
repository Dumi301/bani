import Foundation
import SwiftData

/// A learned merchant/keyword → context association (B3). The context sibling of
/// `CategoryRule`, in its OWN additive SwiftData entity — `Transaction` and
/// `CategoryRule` are both untouched. One row per (normalized keyword, context);
/// `confirmations` accrues every time an expense with that keyword is saved under
/// that context. Once a keyword's dominant context clears the promotion bar
/// (`ContextTrust`), the card pre-selects it regardless of which button was tapped.
///
/// `keyword` is always stored NORMALIZED (lowercased + diacritic-folded), matching
/// `Categorizer.normalize`, so lookups never fold at read time.
@Model
final class ContextRule {
    var id: UUID
    var keyword: String
    var context: TransactionContext
    /// How many saved expenses with this keyword landed in this context.
    var confirmations: Int
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        keyword: String,
        context: TransactionContext,
        confirmations: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.keyword = keyword
        self.context = context
        self.confirmations = confirmations
        self.updatedAt = updatedAt
    }
}

/// Pure promotion math for context pre-selection (B3) — no SwiftData, fully
/// unit-testable. A keyword's dominant context pre-selects once it has at least
/// `minConfirmations` and holds at least `minAccuracy` of that keyword's votes.
enum ContextTrust {
    static let minConfirmations = 3
    static let minAccuracy = 0.80

    /// `votes` maps each context to its confirmation count for one keyword.
    /// Returns the context to pre-select, or `nil` when no context is dominant
    /// enough yet. Deterministic on ties (Personal before Work by raw value).
    static func preselected(_ votes: [TransactionContext: Int]) -> TransactionContext? {
        let total = votes.values.reduce(0, +)
        guard total > 0 else { return nil }
        // Winner: highest count; break ties by rawValue for determinism.
        let winner = votes
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }
            .first
        guard let winner, winner.value >= minConfirmations else { return nil }
        guard Double(winner.value) / Double(total) >= minAccuracy else { return nil }
        return winner.key
    }
}
