import Foundation

/// P11 — executes a `SearchFilter` against the transaction history: structured
/// predicates evaluated IN-MEMORY (house style — no enum `#Predicate`, see
/// `Dedup/DedupService` / `Loans/LoanStore` for the same discipline), free-text
/// terms via the EXISTING keyword search (`TransactionSearch`, never a second
/// implementation), intersected, then ranked (date desc; exact-amount hits
/// boosted). Pure value logic (no SwiftData) so it is unit-tested directly;
/// `RaportHubView` maps live `Transaction`s to `Item`s and back.
enum SmartSearchService {

    /// The fields search + ranking read, reduced from a `Transaction` — mirrors
    /// `TransactionSearch.Fields` but carries the identity + structured columns
    /// (amount, currency, direction, date, project) a filter also matches on.
    struct Item: Identifiable, Equatable, Sendable {
        let id: UUID
        let amount: Decimal
        let currency: Currency
        let direction: TransactionDirection
        let date: Date
        let categoryRef: CategoryRef?
        let projectID: UUID?
        let counterparty: String?
        let descriptionText: String
        let rawTranscript: String?
        let merchant: String?

        init(
            id: UUID, amount: Decimal, currency: Currency, direction: TransactionDirection, date: Date,
            categoryRef: CategoryRef? = nil, projectID: UUID? = nil, counterparty: String? = nil,
            descriptionText: String, rawTranscript: String? = nil, merchant: String? = nil
        ) {
            self.id = id
            self.amount = amount
            self.currency = currency
            self.direction = direction
            self.date = date
            self.categoryRef = categoryRef
            self.projectID = projectID
            self.counterparty = counterparty
            self.descriptionText = descriptionText
            self.rawTranscript = rawTranscript
            self.merchant = merchant
        }
    }

    // MARK: - Orchestration (compile → execute, with the fallback law)

    /// One full smart search: compiles `query` via `QueryCompiler`, then either
    /// executes the resulting `SearchFilter` (structured path) or — the compiler
    /// is unavailable/slow/nothing usable — matches `query` straight through
    /// `TransactionSearch`, ORDER-PRESERVING and unsorted, so the result is
    /// byte-identical to calling the existing keyword search directly on the
    /// same input order (the fallback law).
    static func search(
        query: String,
        now: Date,
        calendar: Calendar,
        items: [Item],
        projects: [ProjectSnapshot],
        people: [PersonSnapshot],
        historicalCounterparties: [String] = [],
        customCategories: [CustomCategorySnapshot] = [],
        learnedRules: [CategoryRuleSnapshot] = [],
        compiler: any QueryCompiling = UnavailableQueryCompiler(),
        timeout: Duration = .seconds(3)
    ) async -> (filter: SearchFilter?, results: [Item]) {
        let filter = await QueryCompiler.compile(
            query: query, now: now, calendar: calendar, projects: projects, people: people,
            historicalCounterparties: historicalCounterparties, customCategories: customCategories,
            learnedRules: learnedRules, compiler: compiler, timeout: timeout
        )
        guard let filter else {
            return (nil, keywordFallback(query, items: items, customCategories: customCategories, learnedRules: learnedRules))
        }
        return (filter, execute(filter, items: items, learnedRules: learnedRules, customCategories: customCategories))
    }

    /// The raw-query path — IDENTICAL matching to `TransactionSearch` (the same
    /// fold, the same category/keyword resolution), preserving `items`' incoming
    /// order exactly like every existing call site (`FinancesView.applySearch`)
    /// already does. This is the golden fallback the byte-identical test proves.
    static func keywordFallback(
        _ query: String, items: [Item],
        customCategories: [CustomCategorySnapshot] = [], learnedRules: [CategoryRuleSnapshot] = []
    ) -> [Item] {
        let q = TransactionSearch.fold(query)
        guard !q.isEmpty else { return items }
        let categories = TransactionSearch.categoriesMatching(foldedQuery: q, learnedRules: learnedRules)
        let customs = TransactionSearch.customCategoriesMatching(foldedQuery: q, customCategories: customCategories, learnedRules: learnedRules)
        return items.filter { item in
            TransactionSearch.matches(fields(item), foldedQuery: q, matchingCategories: categories, matchingCustoms: customs)
        }
    }

    // MARK: - Structured execution

    /// Applies every non-nil `SearchFilter` field as an in-memory predicate
    /// (AND-intersected), routes `freeTextTerms` through `TransactionSearch`,
    /// then ranks the survivors.
    static func execute(
        _ filter: SearchFilter, items: [Item],
        learnedRules: [CategoryRuleSnapshot] = [], customCategories: [CustomCategorySnapshot] = []
    ) -> [Item] {
        var result = items

        if let dateRange = filter.dateRange {
            result = result.filter { $0.date >= dateRange.start && $0.date < dateRange.end }
        }
        if let currency = filter.currency {
            result = result.filter { $0.currency == currency }
        }
        if let direction = filter.direction {
            result = result.filter { $0.direction == direction }
        }
        if let amountMin = filter.amountMin {
            result = result.filter { $0.amount >= amountMin }
        }
        if let amountMax = filter.amountMax {
            result = result.filter { $0.amount <= amountMax }
        }
        if !filter.categoryRefs.isEmpty {
            let refs = Set(filter.categoryRefs)
            result = result.filter { item in item.categoryRef.map(refs.contains) ?? false }
        }
        if !filter.projectIDs.isEmpty {
            let ids = Set(filter.projectIDs)
            result = result.filter { item in item.projectID.map(ids.contains) ?? false }
        }
        if !filter.personNames.isEmpty {
            let folded = Set(filter.personNames.map(Categorizer.normalize))
            result = result.filter { item in
                guard let cp = item.counterparty else { return false }
                return folded.contains(Categorizer.normalize(cp))
            }
        }
        if !filter.freeTextTerms.isEmpty {
            let text = filter.freeTextTerms.joined(separator: " ")
            let q = TransactionSearch.fold(text)
            if !q.isEmpty {
                let categories = TransactionSearch.categoriesMatching(foldedQuery: q, learnedRules: learnedRules)
                let customs = TransactionSearch.customCategoriesMatching(foldedQuery: q, customCategories: customCategories, learnedRules: learnedRules)
                result = result.filter { item in
                    TransactionSearch.matches(fields(item), foldedQuery: q, matchingCategories: categories, matchingCustoms: customs)
                }
            }
        }

        return rank(result, filter: filter)
    }

    // MARK: - Ranking

    /// Date desc; an exact-amount hit (when the filter carries one) sorts first
    /// within that ordering — a stable partition, not a re-fold of the date sort.
    private static func rank(_ items: [Item], filter: SearchFilter) -> [Item] {
        let dateDesc = items.sorted { $0.date > $1.date }
        guard let exact = filter.exactAmount else { return dateDesc }
        let boosted = dateDesc.filter { $0.amount == exact }
        let rest = dateDesc.filter { $0.amount != exact }
        return boosted + rest
    }

    // MARK: - Bridge to TransactionSearch (the existing keyword search)

    private static func fields(_ item: Item) -> TransactionSearch.Fields {
        TransactionSearch.Fields(
            descriptionText: item.descriptionText, rawTranscript: item.rawTranscript,
            merchant: item.merchant, counterparty: item.counterparty,
            category: item.categoryRef?.presetValue, customCategoryID: item.categoryRef?.customID
        )
    }
}

extension SmartSearchService.Item {
    /// Bridges a live `Transaction` into the pure search item.
    init(_ transaction: Transaction) {
        self.init(
            id: transaction.id, amount: transaction.amount, currency: transaction.currency,
            direction: transaction.direction, date: transaction.date, categoryRef: transaction.categoryRef,
            projectID: transaction.projectID, counterparty: transaction.counterparty,
            descriptionText: transaction.descriptionText, rawTranscript: transaction.rawTranscript,
            merchant: transaction.merchant
        )
    }
}
