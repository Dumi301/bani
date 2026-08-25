import Foundation
import SwiftData

/// The Person-registry seam (v1.3), kept out of the views so create/find/merge
/// logic is directly testable. NON-DESTRUCTIVE by design: nothing here EVER
/// rewrites a historical `Transaction.counterparty` / `ScheduledItem.counterparty`
/// string — the registry only formalizes go-forward entry, matched by
/// normalized name (never an FK, see `Person`).
enum PersonStore {

    // MARK: - Normalization

    /// The dedup/lookup key: trimmed, then diacritic-folded + lowercased via
    /// the SAME `Categorizer.normalize` convention every other free-text match
    /// in this app uses (parser, categorizer, search, counterparty grouping).
    /// `"Ștefan"` and `"Stefan"` normalize to the same key.
    static func normalizedKey(_ name: String) -> String {
        Categorizer.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Create / find

    /// An existing registered person whose normalized name matches, if any.
    /// In-memory filter (mirrors the codebase convention of never putting a
    /// derived/computed comparison into a `#Predicate` keypath).
    @MainActor
    static func find(name: String, in modelContext: ModelContext) -> Person? {
        let key = normalizedKey(name)
        guard !key.isEmpty else { return nil }
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        return people.first { $0.normalizedName == key }
    }

    /// Find-or-create by normalized name. Blank/whitespace-only input creates
    /// nothing (`nil`). This is the ONE deliberate, one-tap way a free-text
    /// counterparty becomes a registered `Person` — callers (the "add to
    /// people" affordance) decide when it fires; it is NEVER called
    /// automatically from logging a transaction or scheduled item.
    @MainActor
    @discardableResult
    static func findOrCreate(name: String, kind: PersonKind? = nil, in modelContext: ModelContext) -> Person? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = find(name: clean, in: modelContext) { return existing }
        let created = Person(name: clean, normalizedName: normalizedKey(clean), kind: kind)
        modelContext.insert(created)
        try? modelContext.save()
        return created
    }

    // MARK: - Historical counterparties (read-only)

    /// Distinct historical counterparty strings pooled from BOTH `Transaction`
    /// and `ScheduledItem` rows — "wherever counterparty is entered" needs the
    /// full history, not just one entity. Purely a read: never mutates a
    /// stored string. Roughly most-recent-first (each source sorted
    /// internally; the two pools are concatenated, transactions first).
    static func historicalCounterparties(transactions: [Transaction], scheduledItems: [ScheduledItem]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let pooled = transactions.sorted { $0.date > $1.date }.map(\.counterparty)
            + scheduledItems.sorted { $0.dueDate > $1.dueDate }.map(\.counterparty)
        for candidate in pooled {
            guard let candidate else { continue }
            let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let key = normalizedKey(clean)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(clean)
        }
        return out
    }

    // MARK: - Suggestions (pure)

    /// Autocomplete candidates for a counterparty field (B3): registered
    /// people FIRST, then distinct historical counterparty strings NOT already
    /// covered by the registry — so a formalized person's own free-text
    /// history never duplicates their registry entry. Pure function (no
    /// `ModelContext`), so it is directly unit-testable; callers supply the
    /// already-resolved name lists.
    static func suggestions(
        prefix: String,
        people: [String],
        historicalCounterparties: [String],
        limit: Int = 8
    ) -> [String] {
        let query = normalizedKey(prefix)
        var seenKeys = Set<String>()
        var out: [String] = []

        func consider(_ candidate: String) {
            let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            let key = normalizedKey(clean)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { return }
            guard query.isEmpty || key.contains(query) else { return }
            out.append(clean)
        }

        people.forEach(consider)
        historicalCounterparties.forEach(consider)
        return Array(out.prefix(limit))
    }
}
