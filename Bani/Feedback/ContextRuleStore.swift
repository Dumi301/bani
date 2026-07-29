import Foundation
import SwiftData

/// The SwiftData-backed side of context learning (B3) — the context sibling of
/// `CategoryRuleStore`, using the SAME normalized-keyword mechanics. It accrues a
/// confirmation for (keyword → context) on every save and answers whether a
/// keyword's dominant context is strong enough to pre-select. The pure promotion
/// math lives in `ContextTrust`; this type only bridges it to a `ModelContext`.
@MainActor
enum ContextRuleStore {

    /// The salient keyword a context association is keyed on — the SAME keyword
    /// `CategoryRuleStore.learn` uses, so category and context learning agree on
    /// token identity ("aeroport" → Work, fuel, …).
    private static func keyword(description: String, merchant: String?) -> String {
        let text = Categorizer.categorizationText(description: description, merchant: merchant)
        return Categorizer.salientKeyword(in: text)
    }

    private static func rules(forKeyword keyword: String, in context: ModelContext) -> [ContextRule] {
        guard !keyword.isEmpty else { return [] }
        let descriptor = FetchDescriptor<ContextRule>(predicate: #Predicate { $0.keyword == keyword })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Reading

    /// The context to pre-select for a description(+merchant), or `nil` when no
    /// context is dominant enough yet (≥3 confirmations, ≥80% of the keyword's
    /// votes). The card shows this as a small "auto: <context>" note.
    static func preselectedContext(description: String, merchant: String? = nil, in context: ModelContext) -> TransactionContext? {
        let key = keyword(description: description, merchant: merchant)
        guard !key.isEmpty else { return nil }
        let votes = Dictionary(
            rules(forKeyword: key, in: context).map { ($0.context, $0.confirmations) },
            uniquingKeysWith: +
        )
        return ContextTrust.preselected(votes)
    }

    // MARK: - Writing (the learning path)

    /// Record that an expense with this description(+merchant) was saved under
    /// `finalContext` — accrues a confirmation for (keyword → finalContext). A
    /// context correction is just a save under the corrected context, so this one
    /// call covers both "confirmed" and "corrected" context outcomes.
    static func record(
        finalContext: TransactionContext,
        description: String,
        merchant: String? = nil,
        in context: ModelContext
    ) {
        let key = keyword(description: description, merchant: merchant)
        guard !key.isEmpty else { return }
        if let rule = rules(forKeyword: key, in: context).first(where: { $0.context == finalContext }) {
            rule.confirmations += 1
            rule.updatedAt = .now
        } else {
            context.insert(ContextRule(keyword: key, context: finalContext, confirmations: 1))
        }
        try? context.save()
    }

    // MARK: - Diagnostics (B5)

    static func learnedCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<ContextRule>())) ?? 0
    }

    static func allRules(in context: ModelContext) -> [ContextRule] {
        let descriptor = FetchDescriptor<ContextRule>(sortBy: [SortDescriptor(\ContextRule.confirmations, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
