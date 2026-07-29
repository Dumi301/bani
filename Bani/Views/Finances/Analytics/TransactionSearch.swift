import Foundation

/// Deterministic, offline search for the Finances tab (C). Case- and
/// diacritic-insensitive on BOTH sides — query and data are folded through
/// `Categorizer.normalize` — so "bransament" finds "branșament" and "benzina"
/// finds "benzină".
///
/// A transaction matches when the folded query is a substring of its
/// description, raw transcript, or merchant, OR when the query resolves to the
/// transaction's category — by the category's own label OR any of its seed /
/// learned keywords (so "fuel" and "benzină" both surface fuel entries).
///
/// Pure value logic (no SwiftData) so the matching is unit-tested directly.
enum TransactionSearch {

    /// The fields search reads, reduced from a `Transaction`. Carries the unified
    /// `categoryRef` so a custom category can be matched by id/name (C3).
    struct Fields: Equatable, Sendable {
        var descriptionText: String
        var rawTranscript: String?
        var merchant: String?
        var categoryRef: CategoryRef?

        init(descriptionText: String, rawTranscript: String? = nil, merchant: String? = nil, category: TransactionCategory? = nil, customCategoryID: UUID? = nil) {
            self.descriptionText = descriptionText
            self.rawTranscript = rawTranscript
            self.merchant = merchant
            if let customCategoryID { self.categoryRef = .custom(customCategoryID) }
            else if let category { self.categoryRef = .preset(category) }
            else { self.categoryRef = nil }
        }
    }

    /// Diacritic-fold + lowercase, shared with the categorizer/parser.
    static func fold(_ s: String) -> String { Categorizer.normalize(s) }

    /// Categories whose label OR any keyword (seed + learned) contains the folded
    /// query. Empty query → empty set (the caller treats an empty query as
    /// "match everything" separately).
    static func categoriesMatching(foldedQuery q: String, learnedRules: [CategoryRuleSnapshot]) -> Set<TransactionCategory> {
        guard !q.isEmpty else { return [] }
        var out: Set<TransactionCategory> = []
        for category in TransactionCategory.allCases where fold(category.label).contains(q) {
            out.insert(category)
        }
        // Seed keywords are already stored normalized; fold defensively anyway.
        for seed in CategorySeeds.table where fold(seed.keyword).contains(q) {
            out.insert(seed.category)
        }
        for rule in learnedRules where rule.customCategoryID == nil && fold(rule.keyword).contains(q) {
            out.insert(rule.category)
        }
        return out
    }

    /// Custom-category ids whose NAME contains the folded query, plus any custom
    /// category a learned keyword points at (so "padel" also finds a custom
    /// "Sport" category). Empty query → empty set.
    static func customCategoriesMatching(foldedQuery q: String, customCategories: [CustomCategorySnapshot], learnedRules: [CategoryRuleSnapshot] = []) -> Set<UUID> {
        guard !q.isEmpty else { return [] }
        var out: Set<UUID> = []
        for category in customCategories where fold(category.name).contains(q) {
            out.insert(category.id)
        }
        for rule in learnedRules {
            if let id = rule.customCategoryID, fold(rule.keyword).contains(q) { out.insert(id) }
        }
        return out
    }

    /// Whether `fields` matches the folded query, given the pre-resolved sets of
    /// preset categories and custom-category ids the query maps to.
    static func matches(_ fields: Fields, foldedQuery q: String, matchingCategories: Set<TransactionCategory>, matchingCustoms: Set<UUID> = []) -> Bool {
        guard !q.isEmpty else { return true }
        if fold(fields.descriptionText).contains(q) { return true }
        if let raw = fields.rawTranscript, fold(raw).contains(q) { return true }
        if let merchant = fields.merchant, fold(merchant).contains(q) { return true }
        if let preset = fields.categoryRef?.presetValue, matchingCategories.contains(preset) { return true }
        if let customID = fields.categoryRef?.customID, matchingCustoms.contains(customID) { return true }
        return false
    }
}
