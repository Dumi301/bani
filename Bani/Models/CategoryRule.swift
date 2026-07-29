import Foundation
import SwiftData

/// Where a `CategoryRule` came from. `seed` rules ship with the app; `learned`
/// rules are written when the user corrects a category (see `CategoryRuleStore`).
/// Learned rules always beat seeds on a conflict.
enum CategoryRuleOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case seed
    case learned
}

/// A single keyword → category mapping for the deterministic categorizer
/// (no LLM, no embeddings). Kept in its OWN SwiftData entity — the frozen
/// `Transaction` model gains nothing. Adding this entity to the container is a
/// lightweight, additive migration; existing `Transaction` rows are untouched.
///
/// `keyword` is always stored NORMALIZED (lowercased + diacritic-folded) so a
/// lookup never has to fold at read time — see `Categorizer.normalize`.
@Model
final class CategoryRule {
    var id: UUID
    /// Normalized (lowercased + diacritic-folded) keyword to match against a
    /// transaction's description.
    var keyword: String
    var category: TransactionCategory
    /// C3 — when a keyword is learned onto a user-defined `CustomCategory`, this
    /// holds its id and takes precedence over `category` (see `CategoryRule.ref`).
    /// Additive + optional: a lightweight migration, existing rules migrate to
    /// `nil` and keep mapping to their preset `category`. `category` stays
    /// populated (with `.other`) for a custom rule so the non-optional column is
    /// never empty and legacy readers degrade gracefully.
    var customCategoryID: UUID?
    var origin: CategoryRuleOrigin
    /// How many times this rule has fired on an unedited save — the learned-vs-learned
    /// tie-breaker after keyword length.
    var hitCount: Int
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        keyword: String,
        category: TransactionCategory,
        customCategoryID: UUID? = nil,
        origin: CategoryRuleOrigin,
        hitCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.keyword = keyword
        self.category = category
        self.customCategoryID = customCategoryID
        self.origin = origin
        self.hitCount = hitCount
        self.updatedAt = updatedAt
    }
}
