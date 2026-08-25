import Foundation

/// P10 — the "LLM / self-learning processing unit" seam (VISION §1). One value
/// type describes EVERY raw input the app absorbs before it becomes a record.
///
/// Pure + `Sendable`: carries no `ModelContext`, so the whole interpretation
/// pipeline is unit-testable with no SwiftData and — critically — with the
/// Foundation Models pass behind an injectable seam (CI runners have NO FM
/// runtime, so tests inject `MockUnderstanding`).
enum RawInput: Equatable, Sendable {
    /// A Whisper voice transcript (the Log flow).
    case voiceTranscript(String)
    /// Shared bank-notification text / OCR'd screenshot text (the share flow).
    case sharedText(String)
    /// One imported document/spreadsheet row's descriptive text (the import flow).
    case importRow(String)

    /// The free text to interpret, regardless of source.
    var text: String {
        switch self {
        case .voiceTranscript(let t), .sharedText(let t), .importRow(let t): return t
        }
    }
}

/// Which annotator produced a given field of an `Interpretation`. Recorded so the
/// self-learning loop can attribute a confirm/correct to the layer that guessed
/// (rule = deterministic categorizer/containment, memory = a remembered user
/// correction / learned rule, fm = on-device Foundation Models).
enum Annotator: String, Codable, Hashable, Sendable {
    case rule
    case memory
    case fm
}

/// A resolved project reference the interpreter is CONFIDENT actually exists — an
/// `id` is only ever an existing `Project`'s id (anti-hallucination: FM proposes,
/// deterministic verification against the live registry disposes).
struct ProjectMatch: Equatable, Sendable {
    let id: UUID
    let name: String
    let confidence: Double
}

/// A resolved person reference (counterparty) the interpreter is confident exists.
struct PersonMatch: Equatable, Sendable {
    let name: String
    let confidence: Double
}

/// A remembered, user-authored ground-truth override for a given input, resolved
/// by the caller from the learning stores (learned `CategoryRule` / `CorrectionMemory`).
/// Any field set here beats every model suggestion for that field — user
/// corrections are ground truth (VISION §1 "self-learning").
struct RememberedCorrection: Equatable, Sendable {
    var categoryRef: CategoryRef?

    static let none = RememberedCorrection(categoryRef: nil)
}

/// The interpretation of one raw input: annotations that PRE-FILL review surfaces,
/// each with a 0…1 confidence and the annotator that won it. Interpretation
/// ANNOTATES writes — it never owns the amount (the surface's own parser does that,
/// so money/`Decimal` is never touched here) and never gates a save.
struct Interpretation: Equatable, Sendable {
    /// The unified category guess (preset or custom). Never nil in practice
    /// (`.preset(.other)` fallback), but optional to model "no opinion".
    var categoryRef: CategoryRef?
    var categoryConfidence: Double
    var categoryAnnotator: Annotator?

    /// A verified existing project's id, or nil when the input names none.
    var projectID: UUID?
    var projectConfidence: Double
    var projectAnnotator: Annotator?

    /// A money-direction opinion, or nil when there is no signal (the surface keeps
    /// its own default — `.expense` — so nothing is gated).
    var direction: TransactionDirection?
    var directionConfidence: Double
    var directionAnnotator: Annotator?

    /// A counterparty string that matches an existing registered `Person`, or nil.
    var counterparty: String?
    var counterpartyConfidence: Double
    var counterpartyAnnotator: Annotator?

    /// The confidence at/above which a suggestion PRE-FILLS an empty field; below
    /// it, a surface only OFFERS the suggestion (the chip row) — never auto-fills.
    static let preFillThreshold = 0.5

    /// Brief-shape accessors (`category?` + `customCategoryID?`).
    var category: TransactionCategory? { categoryRef?.presetValue }
    var customCategoryID: UUID? { categoryRef?.customID }

    var shouldPreFillProject: Bool { projectID != nil && projectConfidence >= Self.preFillThreshold }
    var shouldPreFillCounterparty: Bool { counterparty != nil && counterpartyConfidence >= Self.preFillThreshold }
    var shouldPreFillDirection: Bool { direction != nil && directionConfidence >= Self.preFillThreshold }

    /// An empty interpretation — no opinion on any field.
    static let empty = Interpretation(
        categoryRef: nil, categoryConfidence: 0, categoryAnnotator: nil,
        projectID: nil, projectConfidence: 0, projectAnnotator: nil,
        direction: nil, directionConfidence: 0, directionAnnotator: nil,
        counterparty: nil, counterpartyConfidence: 0, counterpartyAnnotator: nil
    )
}

// MARK: - Foundation Models seam

/// What the on-device model is asked to annotate — the text plus the CURRENT
/// registry names, so the model is nudged to reference only things that exist
/// (belt-and-braces; the interpreter re-verifies every proposal anyway).
struct AnnotationRequest: Equatable, Sendable {
    let text: String
    let knownProjects: [String]
    let knownPeople: [String]
}

/// The model's raw proposal. Every field is optional — an empty proposal means
/// "no opinion", exactly like the rule-based fallback. Verified + confidence-gated
/// by `InterpretationService`; a proposed project/person that does not exist is
/// dropped, never surfaced.
struct ModelAnnotation: Equatable, Sendable {
    var category: TransactionCategory?
    var projectName: String?
    var counterparty: String?
    var direction: TransactionDirection?
    /// The model's own confidence in this proposal (0…1).
    var confidence: Double

    static let none = ModelAnnotation(category: nil, projectName: nil, counterparty: nil, direction: nil, confidence: 0)
}

/// The availability-gated Foundation Models refinement seam. Mirrors
/// `TransactionParsing` / `DocumentUnderstanding`: implementations must NOT throw —
/// unavailability or any error resolves to `nil` (a silent fallback to the
/// deterministic pipeline, never a user-visible error). CI injects a mock; the
/// device uses `FoundationModelsAnnotator`.
protocol AnnotationRefining: Sendable {
    /// Whether the model can run right now (FoundationModels availability).
    var isAvailable: Bool { get }
    /// Refine an annotation, or `nil` to defer entirely to the deterministic result.
    func refine(_ request: AnnotationRequest) async -> ModelAnnotation?
}

/// The always-off annotator — the deterministic-only path (older devices, gating,
/// or CI). Makes "FM unavailable ⇒ deterministic behavior" the DEFAULT.
struct UnavailableAnnotator: AnnotationRefining {
    var isAvailable: Bool { false }
    func refine(_ request: AnnotationRequest) async -> ModelAnnotation? { nil }
}
