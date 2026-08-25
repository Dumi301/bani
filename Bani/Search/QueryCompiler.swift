import Foundation

/// P11 — turns a free-text query (RO or EN) into a `SearchFilter` (VISION §1
/// "search engine (smart)"). COMPOSES exactly the P10 pattern:
///
///   FM proposes (availability-gated, raced against a timeout) → deterministic
///   code VERIFIES every project/person/custom-category against the live
///   registry, and RESOLVES every relative-date token against an injected
///   `now` + `Calendar` → a `SearchFilter`, or `nil` when there is nothing usable.
///
/// HARD LAWS (mirrors `InterpretationService`):
/// - Only projects/people/custom-categories that ACTUALLY EXIST are ever kept —
///   FM proposes, deterministic verification disposes (no hallucinated targets).
/// - FM unavailable, slow/hung (raced against `timeout`), erroring, or proposing
///   nothing usable ⇒ `compile` returns `nil` — the caller falls back to the raw
///   query straight through the existing keyword search (byte-identical).
/// - Every date computation resolves against the INJECTED `now` + `Calendar`;
///   `Date()`/`Calendar.current` never appear inline here (testability law).
///
/// Pure + non-isolated (no `ModelContext`) so it runs off the main actor and is
/// unit-testable with a mock `QueryCompiling` (CI has no FM runtime).
enum QueryCompiler {

    // MARK: - Entry point

    static func compile(
        query: String,
        now: Date,
        calendar: Calendar,
        projects: [ProjectSnapshot],
        people: [PersonSnapshot],
        historicalCounterparties: [String] = [],
        customCategories: [CustomCategorySnapshot] = [],
        learnedRules: [CategoryRuleSnapshot] = [],
        compiler: any QueryCompiling = UnavailableQueryCompiler(),
        timeout: Duration = .seconds(3)
    ) async -> SearchFilter? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let personPool = people.map(\.name) + historicalCounterparties
        let request = SearchQueryRequest(
            query: trimmed,
            knownProjects: projects.filter { !$0.archived }.map(\.name),
            knownPeople: personPool,
            knownCustomCategories: customCategories.map(\.name)
        )

        guard let proposal = await refine(using: compiler, request: request, timeout: timeout),
              !proposal.isEmpty else {
            // FM unavailable, timed out, errored, or proposed nothing usable —
            // the "empty compile → fallback marker" (see SearchFilter.isEmpty docs).
            return nil
        }

        var filter = SearchFilter.empty
        filter.dateRange = proposal.relativeDate.map { RelativeDateResolver.resolve($0, now: now, calendar: calendar) }
        filter.amountMin = proposal.amountMin
        filter.amountMax = proposal.amountMax
        filter.exactAmount = proposal.exactAmount
        filter.currency = proposal.currency
        filter.direction = proposal.direction
        filter.categoryRefs = resolveCategoryRefs(
            preset: proposal.presetCategory,
            customName: proposal.customCategoryName,
            customCategories: customCategories,
            learnedRules: learnedRules
        )
        if let projectName = proposal.projectName,
           let verified = InterpretationService.verifyProject(name: projectName, projects: projects) {
            filter.projectIDs = [verified.id]
        }
        if let personName = proposal.personName,
           let verified = verifyPersonName(personName, people: people, historicalCounterparties: historicalCounterparties) {
            filter.personNames = [verified]
        }
        if let remainder = proposal.remainderText?.trimmingCharacters(in: .whitespacesAndNewlines), !remainder.isEmpty {
            filter.freeTextTerms = [remainder]
        }

        guard !filter.isEmpty else { return nil }
        return filter
    }

    // MARK: - Registry verification (anti-hallucination — P10's rule)

    /// Verify a proposed person NAME against the P6 registry FIRST (reusing
    /// `InterpretationService.verifyPerson` verbatim — the same seam, not a
    /// second one), then against real historical counterparty strings (people
    /// are searchable even when never formally registered). Returns nil for
    /// anything that matches neither pool.
    static func verifyPersonName(_ name: String, people: [PersonSnapshot], historicalCounterparties: [String]) -> String? {
        if let verified = InterpretationService.verifyPerson(name: name, people: people) {
            return verified.name
        }
        let key = Categorizer.normalize(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 3 else { return nil }
        if let exact = historicalCounterparties.first(where: { Categorizer.normalize($0) == key }) {
            return exact
        }
        return historicalCounterparties.first { Categorizer.normalize($0).contains(key) }
    }

    /// Verified category refs: a preset is a closed enum (trivially real); a
    /// proposed custom-category NAME is verified via the exact same matching
    /// `TransactionSearch` already uses for keyword search — no second
    /// category-matching implementation.
    private static func resolveCategoryRefs(
        preset: TransactionCategory?,
        customName: String?,
        customCategories: [CustomCategorySnapshot],
        learnedRules: [CategoryRuleSnapshot]
    ) -> [CategoryRef] {
        var out: [CategoryRef] = []
        if let preset { out.append(.preset(preset)) }
        if let customName {
            let folded = Categorizer.normalize(customName)
            let matches = TransactionSearch.customCategoriesMatching(
                foldedQuery: folded, customCategories: customCategories, learnedRules: learnedRules
            )
            out.append(contentsOf: matches.map { .custom($0) })
        }
        return out
    }

    // MARK: - FM race (non-blocking) — identical shape to InterpretationService.refine

    /// Run the compiler, but never longer than `timeout`: a slow or hung model
    /// resolves to nil (the caller falls back). Returns nil immediately when the
    /// compiler is unavailable, so no task is even spawned on CI.
    static func refine(
        using compiler: any QueryCompiling,
        request: SearchQueryRequest,
        timeout: Duration
    ) async -> SearchQueryProposal? {
        guard compiler.isAvailable else { return nil }
        return await withTaskGroup(of: SearchQueryProposal?.self) { group in
            group.addTask { await compiler.compile(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
