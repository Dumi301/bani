import Foundation

/// P11 — the "search engine (smart)" seam (VISION §1 Board 1 / §3: "what did I
/// pay the electrician at the Crângași site last spring" should just work). One
/// value type describes the STRUCTURED interpretation of a free-text query,
/// mirroring the P10 `Interpretation` seam: FM PROPOSES, deterministic code
/// VERIFIES + EXECUTES. Pure + `Sendable` — no `ModelContext`, so the whole
/// compile pipeline is unit-testable with the Foundation Models pass behind an
/// injectable seam (CI has no FM runtime, so tests inject a mock `QueryCompiling`).
struct SearchFilter: Equatable, Sendable {
    /// A relative or explicit date window, already resolved to concrete bounds
    /// by `RelativeDateResolver` against an injected `now` + `Calendar` — NEVER
    /// computed by the model itself.
    var dateRange: DateInterval?
    /// One-sided or two-sided amount bounds ("over 500 lei", "under 100 EUR",
    /// "between 200 and 500"). Either bound may be nil independently.
    var amountMin: Decimal?
    var amountMax: Decimal?
    /// A specific amount mentioned in the query ("the 1200 lei payment") — not a
    /// hard filter, but a ranking boost (`SmartSearchService.rank`).
    var exactAmount: Decimal?
    var currency: Currency?
    var direction: TransactionDirection?
    /// Verified categories only (preset — trivially real, an enum — and/or
    /// custom categories verified against the live registry). Anti-hallucination:
    /// a proposed custom-category name that matches nothing real is dropped.
    var categoryRefs: [CategoryRef]
    /// Verified existing (non-archived) project ids only — a hallucinated
    /// project name is dropped, never offered (P10's rule).
    var projectIDs: [UUID]
    /// Verified names only — matched against the P6 Person registry OR a real
    /// historical `Transaction`/`ScheduledItem` counterparty string. A proposed
    /// name matching neither is dropped.
    var personNames: [String]
    /// Whatever text remains after structured extraction — runs through the
    /// EXISTING keyword search (`TransactionSearch`, incl. `rawTranscript`),
    /// never a second search implementation.
    var freeTextTerms: [String]

    static let empty = SearchFilter(
        dateRange: nil, amountMin: nil, amountMax: nil, exactAmount: nil,
        currency: nil, direction: nil, categoryRefs: [], projectIDs: [],
        personNames: [], freeTextTerms: []
    )

    /// True when the filter carries NO signal at all — structured or free-text.
    /// This is the "empty compile → fallback marker": `QueryCompiler` returns
    /// `nil` rather than an empty filter, so the caller falls back to the raw
    /// query straight through the existing keyword search (byte-identical).
    var isEmpty: Bool {
        dateRange == nil && amountMin == nil && amountMax == nil && exactAmount == nil &&
        currency == nil && direction == nil && categoryRefs.isEmpty && projectIDs.isEmpty &&
        personNames.isEmpty && freeTextTerms.isEmpty
    }
}

// MARK: - Foundation Models seam (mirrors Understanding/Interpretation.swift)

/// What the on-device model is asked to compile — the raw query plus the
/// CURRENT registry names, so the model is nudged to reference only things
/// that exist (belt-and-braces; `QueryCompiler` re-verifies every proposal).
struct SearchQueryRequest: Equatable, Sendable {
    let query: String
    let knownProjects: [String]
    let knownPeople: [String]
    let knownCustomCategories: [String]
}

/// A closed vocabulary of relative-date phrases (RO or EN) the model may
/// recognize in a query. The model NEVER computes a date itself — it only
/// classifies the phrase into one of these tokens; `RelativeDateResolver` turns
/// the token into an actual `DateInterval` against an injected `now` +
/// `Calendar`, so every date computation stays 100% deterministic and testable.
enum RelativeDateToken: String, CaseIterable, Sendable {
    case today, yesterday
    case thisWeek, lastWeek
    case thisMonth, lastMonth
    case thisYear, lastYear
    case thisSpring, lastSpring
    case thisSummer, lastSummer
    case thisFall, lastFall
    case thisWinter, lastWinter
    case january, february, march, april, may, june, july, august, september, october, november, december
}

/// The model's raw proposal. Every field is optional — an empty proposal means
/// "no opinion", exactly like P10's `ModelAnnotation`. Verified + resolved by
/// `QueryCompiler`; a proposed project/person/custom-category that does not
/// exist is dropped, never surfaced. Money is a plain `Decimal?` (never `Double`).
struct SearchQueryProposal: Equatable, Sendable {
    var relativeDate: RelativeDateToken? = nil
    var amountMin: Decimal? = nil
    var amountMax: Decimal? = nil
    var exactAmount: Decimal? = nil
    var currency: Currency? = nil
    var direction: TransactionDirection? = nil
    /// A preset category is a closed enum — trivially real, no verification needed.
    var presetCategory: TransactionCategory? = nil
    /// A free-text custom-category name — verified against the live registry.
    var customCategoryName: String? = nil
    var projectName: String? = nil
    var personName: String? = nil
    /// Whatever text the model could not resolve to a structured field.
    var remainderText: String? = nil

    static let none = SearchQueryProposal()

    /// Whether the model proposed literally nothing.
    var isEmpty: Bool {
        relativeDate == nil && amountMin == nil && amountMax == nil && exactAmount == nil &&
        currency == nil && direction == nil && presetCategory == nil && customCategoryName == nil &&
        projectName == nil && personName == nil &&
        (remainderText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// The availability-gated Foundation Models query-compiling seam. Mirrors
/// `AnnotationRefining` (P10) exactly: implementations must NOT throw —
/// unavailability or any error resolves to `nil` (a silent fallback to the raw
/// keyword search, never a user-visible error). CI injects a mock; the device
/// uses `FoundationModelsQueryCompiler`.
protocol QueryCompiling: Sendable {
    /// Whether the model can run right now (FoundationModels availability).
    var isAvailable: Bool { get }
    /// Compile a query, or `nil` to defer entirely to the raw keyword-search fallback.
    func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal?
}

/// The always-off compiler — the fallback-only path (older devices, gating, or
/// CI). Makes "FM unavailable ⇒ raw keyword search" the DEFAULT, exactly like
/// P10's `UnavailableAnnotator`.
struct UnavailableQueryCompiler: QueryCompiling {
    var isAvailable: Bool { false }
    func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal? { nil }
}
