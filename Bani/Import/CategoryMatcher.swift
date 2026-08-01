import Foundation

/// Matches a category-column value to an existing category (C2). Presets are
/// matched on their RO + EN display names (and enum raw values / common aliases);
/// custom categories on their (folded) names. All comparison is via
/// `Categorizer.normalize` so "Alimente", "alimente", "ALIMENTE" and "Alimenté"
/// all collapse to the same key. Unmatched values are surfaced to the user for a
/// per-value decision (map / create / leave uncategorized).
struct CategoryMatcher: Sendable {

    /// Preset display names + aliases, RO + EN, keyed by preset. Kept in sync with
    /// `Localizable.xcstrings` `category.*`; extra common synonyms improve recall.
    static let presetAliases: [TransactionCategory: [String]] = [
        .fuel:          ["fuel", "combustibil", "benzina", "carburant", "motorina"],
        .groceries:     ["groceries", "alimente", "mancare", "supermarket"],
        .dining:        ["dining", "restaurant", "cafenea", "bar"],
        .transport:     ["transport", "taxi", "transportation"],
        .utilities:     ["utilities", "utilitati", "facturi", "factura"],
        .shopping:      ["shopping", "cumparaturi", "haine", "imbracaminte"],
        .health:        ["health", "sanatate", "farmacie", "medical"],
        .entertainment: ["entertainment", "divertisment", "distractie"],
        .other:         ["other", "altele", "alt", "diverse", "necategorisit", "uncategorized"],
    ]

    /// normalized-name → CategoryRef, built from presets + the current customs.
    private let index: [String: CategoryRef]

    init(customCategories: [CustomCategorySnapshot]) {
        var map: [String: CategoryRef] = [:]
        // Presets first.
        for (category, aliases) in Self.presetAliases {
            for alias in aliases {
                map[Categorizer.normalize(alias)] = .preset(category)
            }
            // Enum raw value ("fuel") always maps too.
            map[Categorizer.normalize(category.rawValue)] = .preset(category)
        }
        // Customs win on a name collision (user intent is explicit).
        for custom in customCategories {
            map[Categorizer.normalize(custom.name)] = .custom(custom.id)
        }
        self.index = map
    }

    /// The matched category for a raw cell value, or `nil` when nothing matches.
    func match(_ value: String) -> CategoryRef? {
        let key = Categorizer.normalize(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return nil }
        return index[key]
    }

    /// The distinct non-empty category values in a column that do NOT match any
    /// existing category — the wizard lists these for a per-value decision. Order
    /// is by first appearance (deterministic).
    func unmatchedValues(in values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = Categorizer.normalize(trimmed)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if match(trimmed) == nil { out.append(trimmed) }
        }
        return out
    }
}
