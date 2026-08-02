import Foundation

/// The real-estate/finance custom categories Bani pre-seeds on first launch
/// (spec §4.2 + C2/C3/C4). Each maps 1:1 to a `CustomCategory` created at first
/// launch (idempotent, keyed by `displayName`). Family parsers emit these tokens
/// so the fixture oracle can assert categories WITHOUT a live `ModelContext`; the
/// commit step resolves a token → the concrete custom id via `PresetSeeding`.
///
/// H2 — colors draw ONLY from the existing 8-swatch semantic palette
/// (`BaniCustom0…7`), repeating as `colorIndex = order mod 8`. The declaration
/// order is the spec's rough frequency order, so categories adjacent in that
/// order get different swatches. No new color assets — the zero-hardcoded-colors
/// rule stays absolute.
enum SeededCustomCategory: String, CaseIterable, Sendable, Equatable {
    case cheltuieliPersonale
    case transferNumerar
    case comisioaneBancare
    case achizitie
    case materialeConstructii
    case manopera
    case notariatTaxe
    case cadastruIntabulare
    case amenajareMobilier
    case impoziteTaxe
    case comisionAgentie
    case imprumuturi
    case dobanda
    case salariuIncasari
    case platiPersoane
    case incasariPersoane

    /// The user-visible name (Romanian; kept verbatim as the `CustomCategory.name`).
    /// Also the idempotency key for find-or-create seeding.
    var displayName: String {
        switch self {
        case .cheltuieliPersonale: "Cheltuieli personale"
        case .transferNumerar: "Transfer / numerar"
        case .comisioaneBancare: "Comisioane bancare"
        case .achizitie: "Achiziție"
        case .materialeConstructii: "Materiale construcții"
        case .manopera: "Manoperă"
        case .notariatTaxe: "Notariat & taxe legale"
        case .cadastruIntabulare: "Cadastru & intabulare"
        case .amenajareMobilier: "Amenajare & mobilier"
        case .impoziteTaxe: "Impozite & taxe"
        case .comisionAgentie: "Comision agenție"
        case .imprumuturi: "Împrumuturi"
        case .dobanda: "Dobândă"
        case .salariuIncasari: "Salariu / Încasări"
        case .platiPersoane: "Plăți persoane"
        case .incasariPersoane: "Încasări persoane"
        }
    }

    /// An SF Symbol for the seeded custom (all confirmed system symbols).
    var symbolName: String {
        switch self {
        case .cheltuieliPersonale: "creditcard.fill"
        case .transferNumerar: "arrow.left.arrow.right"
        case .comisioaneBancare: "building.columns.fill"
        case .achizitie: "house.fill"
        case .materialeConstructii: "shippingbox.fill"
        case .manopera: "hammer.fill"
        case .notariatTaxe: "doc.text.fill"
        case .cadastruIntabulare: "map.fill"
        case .amenajareMobilier: "paintbrush.fill"
        case .impoziteTaxe: "percent"
        case .comisionAgentie: "briefcase.fill"
        case .imprumuturi: "arrow.triangle.2.circlepath"
        case .dobanda: "banknote.fill"
        case .salariuIncasari: "dollarsign.circle.fill"
        case .platiPersoane: "person.fill"
        case .incasariPersoane: "person.2.fill"
        }
    }

    /// Declaration order (stable across launches — never reorder, the color +
    /// seeding depend on it).
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// H2 — swatch index into the fixed 8-color palette.
    var colorIndex: Int { order % 8 }
}

/// The OBSERVATII / free-text keyword → seeded-custom vocabulary (spec §4.2).
/// ONE source of truth: the Family-A parser categorizes each row's `OBSERVATII`
/// through this table, AND `PresetSeeding` seeds the identical keyword→custom
/// `CategoryRule`s so by-description categorization (voice/manual/generic import)
/// auto-fires the same way. All keywords are pre-normalized (fold + lowercase) to
/// match `Categorizer.normalize` at match time.
enum ObservatiiVocabulary {
    /// (normalized keyword, target). Longest-keyword-wins is handled by the
    /// categorizer's precedence; multi-word keys (e.g. "taxa pv") match as a
    /// substring, single-word keys as a whole token.
    static let table: [(keyword: String, category: SeededCustomCategory)] = [
        // Achiziție
        ("achizitie", .achizitie), ("avans", .achizitie), ("dif plata", .achizitie),
        // Notariat & taxe legale
        ("notariat", .notariatTaxe), ("notar", .notariatTaxe), ("avize", .notariatTaxe),
        ("taxa pv", .notariatTaxe), ("taxa cu", .notariatTaxe), ("ocpi", .notariatTaxe),
        // Cadastru & intabulare
        ("cadastru", .cadastruIntabulare), ("intabulare", .cadastruIntabulare),
        ("topo", .cadastruIntabulare), ("carte funciara", .cadastruIntabulare),
        // Materiale construcții
        ("materiale", .materialeConstructii), ("beton", .materialeConstructii),
        ("nisip", .materialeConstructii), ("gard", .materialeConstructii),
        ("sanitare", .materialeConstructii), ("electrice", .materialeConstructii),
        ("instalatii", .materialeConstructii), ("ciment", .materialeConstructii),
        // Manoperă
        ("manopera", .manopera), ("necalificat", .manopera),
        // Amenajare & mobilier
        ("amenajare", .amenajareMobilier), ("designer", .amenajareMobilier),
        ("mobila", .amenajareMobilier), ("curatare", .amenajareMobilier),
        ("curat", .amenajareMobilier),
        // Impozite & taxe
        ("impozit", .impoziteTaxe),
        // Comision (default = bank fee; Family A overrides to agency in-parser)
        ("comision", .comisioaneBancare),
        // Cash moves / transfers → neutral
        ("transfer", .transferNumerar), ("depunere", .transferNumerar),
        ("retragere", .transferNumerar), ("schimb valutar", .transferNumerar),
        // Loans → neutral
        ("imprumut", .imprumuturi), ("restituire", .imprumuturi),
        // Finance income
        ("dobanda", .dobanda), ("salariu", .salariuIncasari), ("incasare", .salariuIncasari),
        // Personal card spend
        ("cheltuieli personale", .cheltuieliPersonale),
    ]

    /// Longest-matching keyword for a normalized free-text label, or `nil`.
    /// Single-word keys match a whole token; multi-word keys match a substring.
    static func match(_ normalized: String) -> SeededCustomCategory? {
        let tokens = Set(Categorizer.tokenize(normalized))
        var best: (keyword: String, category: SeededCustomCategory)?
        for entry in table {
            let hit = entry.keyword.contains(" ")
                ? normalized.contains(entry.keyword)
                : tokens.contains(entry.keyword)
            if hit, entry.keyword.count > (best?.keyword.count ?? 0) {
                best = entry
            }
        }
        return best?.category
    }
}
