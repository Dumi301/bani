import Foundation
import SwiftData

/// The SwiftData-backed side of categorization: it seeds the rule table, reads
/// rules for a guess, and writes learned rules / hit-counts back. The pure
/// matching logic lives in `Categorizer`; this type only bridges it to a
/// `ModelContext`.
///
/// This is the SINGLE learning seam. The confirmation card (voice), the manual
/// entry sheet, and the transaction edit flow all call in here — there is never
/// a second, divergent copy of the learning rules (see the D2 contract).
@MainActor
enum CategoryRuleStore {

    // MARK: - Seeding

    /// Inserts the seed table on first launch — only when the store is empty, so
    /// it is idempotent and safe to call on every launch. Learned rules and
    /// hit-counts accumulated on later launches are never disturbed.
    static func seedIfNeeded(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<CategoryRule>())) ?? 0
        guard existing == 0 else { return }
        for seed in CategorySeeds.table {
            context.insert(CategoryRule(keyword: seed.keyword, category: seed.category, origin: .seed))
        }
        try? context.save()
    }

    // MARK: - Reading

    private static func snapshots(_ context: ModelContext) -> [CategoryRuleSnapshot] {
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        return rules.map {
            CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, origin: $0.origin, hitCount: $0.hitCount)
        }
    }

    /// The category guess for a description (+ optional merchant). `.other` when
    /// nothing matches — the chip is never empty.
    static func guess(description: String, merchant: String? = nil, in context: ModelContext) -> TransactionCategory {
        let text = Categorizer.categorizationText(description: description, merchant: merchant)
        return Categorizer.category(for: text, rules: snapshots(context))
    }

    /// The full winning rule (so callers can reinforce exactly the rule that fired).
    static func bestMatch(description: String, merchant: String? = nil, in context: ModelContext) -> CategoryRuleSnapshot? {
        let text = Categorizer.categorizationText(description: description, merchant: merchant)
        return Categorizer.bestMatch(for: text, rules: snapshots(context))
    }

    /// The persistent `id` of the rule that fires for a description(+merchant) —
    /// the stable key the feedback ledger scores trust on (B4). `nil` when no rule
    /// matches (the guess is `.other`, which is never trusted).
    static func firedRuleID(description: String, merchant: String? = nil, in context: ModelContext) -> UUID? {
        guard let match = bestMatch(description: description, merchant: merchant, in: context) else { return nil }
        let keyword = match.keyword
        let descriptor = FetchDescriptor<CategoryRule>(predicate: #Predicate { $0.keyword == keyword })
        let rules = (try? context.fetch(descriptor)) ?? []
        return rules.first { $0.origin == match.origin }?.id
    }

    // MARK: - Writing (the learning path, C4)

    /// A user corrected the category → remember it. Extracts the salient keyword
    /// from the description and upserts a `learned` rule (learned beats seed).
    static func learn(
        correctedCategory: TransactionCategory,
        description: String,
        merchant: String? = nil,
        in context: ModelContext
    ) {
        let text = Categorizer.categorizationText(description: description, merchant: merchant)
        let keyword = Categorizer.salientKeyword(in: text)
        guard !keyword.isEmpty else { return }
        upsertLearned(keyword: keyword, category: correctedCategory, in: context)
    }

    /// An unedited save that matched a rule → bump that rule's `hitCount`,
    /// nudging it up the length/hit tie-breaker for next time.
    static func reinforce(keyword: String, origin: CategoryRuleOrigin, in context: ModelContext) {
        guard let rule = fetchRule(keyword: keyword, origin: origin, in: context) else { return }
        rule.hitCount += 1
        rule.updatedAt = .now
        try? context.save()
    }

    // MARK: - Upsert helpers

    private static func upsertLearned(keyword: String, category: TransactionCategory, in context: ModelContext) {
        if let existing = fetchRule(keyword: keyword, origin: .learned, in: context) {
            existing.category = category
            existing.hitCount += 1
            existing.updatedAt = .now
        } else {
            context.insert(CategoryRule(keyword: keyword, category: category, origin: .learned, hitCount: 1))
        }
        try? context.save()
    }

    private static func fetchRule(keyword: String, origin: CategoryRuleOrigin, in context: ModelContext) -> CategoryRule? {
        // Predicate only over the String keyword — #Predicate can't reliably
        // translate an enum property comparison, so `origin` is filtered in
        // memory (a keyword yields at most a seed + a learned rule).
        let descriptor = FetchDescriptor<CategoryRule>(
            predicate: #Predicate { $0.keyword == keyword }
        )
        let rules = (try? context.fetch(descriptor)) ?? []
        return rules.first { $0.origin == origin }
    }
}
