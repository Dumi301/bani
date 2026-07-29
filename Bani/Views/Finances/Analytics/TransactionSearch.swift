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

    /// The fields search reads, reduced from a `Transaction`.
    struct Fields: Equatable, Sendable {
        var descriptionText: String
        var rawTranscript: String?
        var merchant: String?
        var category: TransactionCategory?

        init(descriptionText: String, rawTranscript: String? = nil, merchant: String? = nil, category: TransactionCategory? = nil) {
            self.descriptionText = descriptionText
            self.rawTranscript = rawTranscript
            self.merchant = merchant
            self.category = category
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
        for rule in learnedRules where fold(rule.keyword).contains(q) {
            out.insert(rule.category)
        }
        return out
    }

    /// Whether `fields` matches the folded query, given the pre-resolved set of
    /// categories the query maps to (from `categoriesMatching`).
    static func matches(_ fields: Fields, foldedQuery q: String, matchingCategories: Set<TransactionCategory>) -> Bool {
        guard !q.isEmpty else { return true }
        if fold(fields.descriptionText).contains(q) { return true }
        if let raw = fields.rawTranscript, fold(raw).contains(q) { return true }
        if let merchant = fields.merchant, fold(merchant).contains(q) { return true }
        if let category = fields.category, matchingCategories.contains(category) { return true }
        return false
    }
}
