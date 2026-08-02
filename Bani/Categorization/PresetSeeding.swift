import Foundation
import SwiftData

/// First-launch seeding of the real-estate/finance custom categories (C2) and
/// their OBSERVATII keyword rules. Runs once (marker-gated) but is fully
/// idempotent — every create is find-or-create by normalized name, so an
/// upgrading user who already made a same-named custom keeps theirs.
///
/// Ordering vs `CategoryRuleStore.seedIfNeeded`: the preset keyword table is
/// seeded first (it gates on an empty rule table), THEN this runs and adds the
/// custom categories + their keyword rules under its own marker. Upgraders (whose
/// rule table is already non-empty) still get the customs, because this gate is
/// independent.
///
/// Deliberately NOT `@MainActor`: `ensureCustoms` / `resolutionMap` are called by
/// the background `ImportCommitRunner` actor on ITS own `ModelContext`, so they
/// must run in the caller's isolation, not hop to main. `seedIfNeeded` is invoked
/// from `BaniApp` on the main context.
enum PresetSeeding {

    static let marker = "presetCustomsSeededV1"

    /// Create the 16 seeded customs (if absent) + their OBSERVATII rules (if the
    /// keyword has no rule yet). Safe to call every launch.
    static func seedIfNeeded(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        let map = ensureCustoms(in: context)
        seedObservatiiRules(map: map, in: context)
        try? context.save()
        UserDefaults.standard.set(true, forKey: marker)
    }

    /// Find-or-create every seeded custom; returns the token → id resolution map
    /// the import commit uses. Idempotent.
    @discardableResult
    static func ensureCustoms(in context: ModelContext) -> [SeededCustomCategory: UUID] {
        let existing = (try? context.fetch(FetchDescriptor<CustomCategory>())) ?? []
        var byName: [String: UUID] = [:]
        for c in existing { byName[Categorizer.normalize(c.name)] = c.id }

        var map: [SeededCustomCategory: UUID] = [:]
        for token in SeededCustomCategory.allCases {
            let key = Categorizer.normalize(token.displayName)
            if let id = byName[key] {
                map[token] = id
            } else {
                let created = CustomCategory(name: token.displayName, symbolName: token.symbolName, colorIndex: token.colorIndex)
                context.insert(created)
                byName[key] = created.id
                map[token] = created.id
            }
        }
        return map
    }

    /// Seed one `.seed` `CategoryRule` per OBSERVATII keyword → its custom id, so
    /// by-description categorization auto-fires (Family A rows, voice, manual).
    /// Skips a keyword that already has any rule (idempotent).
    private static func seedObservatiiRules(map: [SeededCustomCategory: UUID], in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        var seenKeywords = Set(existing.map(\.keyword))
        for entry in ObservatiiVocabulary.table {
            guard let customID = map[entry.category] else { continue }
            guard !seenKeywords.contains(entry.keyword) else { continue }
            context.insert(CategoryRule(keyword: entry.keyword, category: .other, customCategoryID: customID, origin: .seed))
            seenKeywords.insert(entry.keyword)
        }
    }

    /// Live token → id map (creating any missing customs). Used by the import
    /// commit to resolve a family parser's `DraftCategory.seededCustom`.
    static func resolutionMap(in context: ModelContext) -> [SeededCustomCategory: UUID] {
        ensureCustoms(in: context)
    }
}
