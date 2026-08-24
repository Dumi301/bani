import Foundation

/// P10 — the single entry point that turns any `RawInput` into an `Interpretation`
/// (VISION §1 "LLM / self-learning processing unit"). It COMPOSES the existing
/// deterministic pipeline with an availability-gated Foundation Models refinement:
///
///   rule-based parse → Categorizer → (memory/learned override) → FM refinement
///   → verify every project/person against the live registry → confidence-gate.
///
/// HARD LAWS (VISION §1 / PLAN):
/// - Interpretation ANNOTATES writes, it never gates them. When FM is unavailable
///   (older devices, gating, CI) the output is exactly the deterministic pipeline —
///   the fallback IS the current behavior.
/// - A remembered user correction (a learned `CategoryRule`, or an injected
///   `RememberedCorrection`) OVERRIDES the model — user corrections are ground truth.
/// - Only projects/people that ACTUALLY EXIST are ever offered (FM proposes,
///   deterministic verification disposes — no hallucinated targets).
/// - Non-blocking: the FM pass is raced against a timeout, so a slow/hung model can
///   never delay or alter the deterministic result (proven by the timeout test).
///
/// Pure + non-isolated (no `ModelContext`) so it runs off the main actor and the
/// whole thing is unit-testable with a mock annotator.
enum InterpretationService {

    // MARK: - Tunable confidences (0…1)

    /// A learned rule / remembered correction is user ground truth.
    static let learnedConfidence = 0.9
    /// A seed (shipped) rule is a decent-but-generic guess.
    static let seedConfidence = 0.6
    /// The direction read off a bank-notification's income/expense markers.
    static let shareDirectionConfidence = 0.7
    /// A contiguous, whole-phrase name match against the registry.
    static let phraseMatchConfidence = 0.85
    /// A single whole-token name match.
    static let tokenMatchConfidence = 0.75
    /// A longer-name substring match (no token boundary).
    static let substringMatchConfidence = 0.7
    /// An order-free "all name tokens present" multi-word match.
    static let scatteredMatchConfidence = 0.6

    // MARK: - Entry point

    /// Annotate one raw input. `annotator` defaults to the deterministic-only path,
    /// so callers that never inject FM get the exact pre-P10 behavior. `timeout`
    /// caps how long the FM pass may take before the deterministic result stands.
    static func annotate(
        _ input: RawInput,
        rules: [CategoryRuleSnapshot],
        projects: [ProjectSnapshot],
        people: [PersonSnapshot],
        remembered: RememberedCorrection? = nil,
        annotator: any AnnotationRefining = UnavailableAnnotator(),
        timeout: Duration = .seconds(3)
    ) async -> Interpretation {
        let text = input.text
        let base = deterministicBase(for: input)

        // Deterministic layer — always available, always first.
        let categoryMatch = Categorizer.bestMatch(for: base.categorizationText, rules: rules)
        let projectMatch = inferProject(text: text, projects: projects)
        let counterpartyMatch = inferCounterparty(text: text, people: people)

        // FM layer — raced against the timeout; nil when unavailable/slow/error.
        let request = AnnotationRequest(
            text: text,
            knownProjects: projects.filter { !$0.archived }.map(\.name),
            knownPeople: people.map(\.name)
        )
        let model = await refine(using: annotator, request: request, timeout: timeout)

        var out = Interpretation.empty
        resolveCategory(&out, match: categoryMatch, remembered: remembered, model: model)
        resolveProject(&out, deterministic: projectMatch, model: model, projects: projects)
        resolveCounterparty(&out, deterministic: counterpartyMatch, model: model, people: people)
        resolveDirection(&out, base: base, model: model)
        return out
    }

    // MARK: - Field resolution

    private static func resolveCategory(
        _ out: inout Interpretation,
        match: CategoryRuleSnapshot?,
        remembered: RememberedCorrection?,
        model: ModelAnnotation?
    ) {
        // 1. A learned rule (a remembered user correction) is ground truth.
        if let match, match.origin == .learned {
            out.categoryRef = match.ref
            out.categoryConfidence = learnedConfidence
            out.categoryAnnotator = .memory
            return
        }
        // 2. An explicitly injected remembered correction is also ground truth.
        if let ref = remembered?.categoryRef {
            out.categoryRef = ref
            out.categoryConfidence = learnedConfidence
            out.categoryAnnotator = .memory
            return
        }
        // 3. The model refines the generic guess (a preset enum needs no verification).
        if let category = model?.category {
            out.categoryRef = .preset(category)
            out.categoryConfidence = clamp(model?.confidence ?? 0)
            out.categoryAnnotator = .fm
            return
        }
        // 4. A shipped seed rule.
        if let match {
            out.categoryRef = match.ref
            out.categoryConfidence = seedConfidence
            out.categoryAnnotator = .rule
            return
        }
        // 5. Nothing matched — the chip is never empty, but there is no confidence.
        out.categoryRef = .preset(.other)
        out.categoryConfidence = 0
        out.categoryAnnotator = .rule
    }

    private static func resolveProject(
        _ out: inout Interpretation,
        deterministic: ProjectMatch?,
        model: ModelAnnotation?,
        projects: [ProjectSnapshot]
    ) {
        // Deterministic containment is grounded in the actual tokens → preferred.
        if let deterministic {
            out.projectID = deterministic.id
            out.projectConfidence = deterministic.confidence
            out.projectAnnotator = .rule
            return
        }
        // The model may PROPOSE a project name; it is offered ONLY if it exists.
        if let name = model?.projectName, let verified = verifyProject(name: name, projects: projects) {
            out.projectID = verified.id
            out.projectConfidence = clamp(model?.confidence ?? 0)
            out.projectAnnotator = .fm
        }
    }

    private static func resolveCounterparty(
        _ out: inout Interpretation,
        deterministic: PersonMatch?,
        model: ModelAnnotation?,
        people: [PersonSnapshot]
    ) {
        if let deterministic {
            out.counterparty = deterministic.name
            out.counterpartyConfidence = deterministic.confidence
            out.counterpartyAnnotator = .rule
            return
        }
        if let name = model?.counterparty, let verified = verifyPerson(name: name, people: people) {
            out.counterparty = verified.name
            out.counterpartyConfidence = clamp(model?.confidence ?? 0)
            out.counterpartyAnnotator = .fm
        }
    }

    private static func resolveDirection(
        _ out: inout Interpretation,
        base: DeterministicBase,
        model: ModelAnnotation?
    ) {
        if let direction = base.direction {
            out.direction = direction
            out.directionConfidence = base.directionConfidence
            out.directionAnnotator = .rule
            return
        }
        if let direction = model?.direction {
            out.direction = direction
            out.directionConfidence = clamp(model?.confidence ?? 0)
            out.directionAnnotator = .fm
        }
    }

    // MARK: - Deterministic base (source-specific parse)

    struct DeterministicBase: Equatable, Sendable {
        let categorizationText: String
        let direction: TransactionDirection?
        let directionConfidence: Double
    }

    /// The deterministic parse per source: the text the categorizer sees, and any
    /// direction the source's own parser can read. This is the pre-P10 behavior,
    /// reused verbatim so the FM-off path is byte-identical to what shipped.
    static func deterministicBase(for input: RawInput) -> DeterministicBase {
        switch input {
        case .sharedText(let text):
            // A bank notification reads its own direction + merchant.
            let parse = BankNotificationParser.parse(text)
            let catText = Categorizer.categorizationText(description: parse.merchant ?? text, merchant: parse.merchant)
            return DeterministicBase(categorizationText: catText, direction: parse.direction, directionConfidence: shareDirectionConfidence)
        case .voiceTranscript(let text), .importRow(let text):
            // Voice / imported rows: strip the amount, categorize the remainder.
            let parse = RuleBasedParser.parseSync(text)
            let catText = Categorizer.categorizationText(description: parse.descriptionText, merchant: parse.merchant)
            return DeterministicBase(categorizationText: catText, direction: nil, directionConfidence: 0)
        }
    }

    // MARK: - Registry matching (pure, synchronous — used by the review surfaces)

    /// The most specific existing project whose name is referenced by `text`, or
    /// nil. Normalized (diacritic-folded) containment, longest name wins. NEVER
    /// returns a project that is not in `projects` — this is the anti-hallucination
    /// floor for both the deterministic and FM paths.
    static func inferProject(text: String, projects: [ProjectSnapshot]) -> ProjectMatch? {
        let norm = Categorizer.normalize(text)
        let tokens = Set(Categorizer.tokenize(norm))
        var best: (match: ProjectMatch, weight: Int)?
        for project in projects where !project.archived {
            guard let confidence = nameConfidence(name: project.name, inNormalized: norm, tokens: tokens) else { continue }
            let weight = Categorizer.normalize(project.name).count
            if best == nil || weight > best!.weight {
                best = (ProjectMatch(id: project.id, name: project.name, confidence: confidence), weight)
            }
        }
        return best?.match
    }

    /// The most specific existing person referenced by `text`, or nil.
    static func inferCounterparty(text: String, people: [PersonSnapshot]) -> PersonMatch? {
        let norm = Categorizer.normalize(text)
        let tokens = Set(Categorizer.tokenize(norm))
        var best: (match: PersonMatch, weight: Int)?
        for person in people {
            guard let confidence = nameConfidence(name: person.name, inNormalized: norm, tokens: tokens) else { continue }
            let weight = person.normalizedName.count
            if best == nil || weight > best!.weight {
                best = (PersonMatch(name: person.name, confidence: confidence), weight)
            }
        }
        return best?.match
    }

    /// Verify an FM-proposed project NAME against the live registry: exact
    /// normalized-name equality first, else fall back to containment inference.
    /// Returns nil for anything that does not exist.
    static func verifyProject(name: String, projects: [ProjectSnapshot]) -> ProjectMatch? {
        let key = Categorizer.normalize(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let exact = projects.first(where: { !$0.archived && Categorizer.normalize($0.name) == key }) {
            return ProjectMatch(id: exact.id, name: exact.name, confidence: 1)
        }
        return inferProject(text: name, projects: projects)
    }

    /// Verify an FM-proposed counterparty NAME against the People registry.
    static func verifyPerson(name: String, people: [PersonSnapshot]) -> PersonMatch? {
        let key = Categorizer.normalize(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let exact = people.first(where: { $0.normalizedName == key }) {
            return PersonMatch(name: exact.name, confidence: 1)
        }
        return inferCounterparty(text: name, people: people)
    }

    /// The confidence that `name` is referenced in the already-normalized `text`
    /// (with pre-tokenized `tokens`), or nil for no match. Names shorter than 3
    /// folded characters never match (too generic to be safe).
    private static func nameConfidence(name: String, inNormalized norm: String, tokens: Set<String>) -> Double? {
        let nameNorm = Categorizer.normalize(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard nameNorm.count >= 3 else { return nil }
        if nameNorm.contains(" ") {
            if norm.contains(nameNorm) { return phraseMatchConfidence }
            let nameTokens = Categorizer.tokenize(nameNorm).filter { $0.count >= 3 }
            guard !nameTokens.isEmpty, nameTokens.allSatisfy({ tokens.contains($0) }) else { return nil }
            return scatteredMatchConfidence
        } else {
            if tokens.contains(nameNorm) { return tokenMatchConfidence }
            if nameNorm.count >= 5, norm.contains(nameNorm) { return substringMatchConfidence }
            return nil
        }
    }

    // MARK: - FM race (non-blocking)

    /// Run the annotator, but never longer than `timeout`: a slow or hung model
    /// resolves to nil (the deterministic result stands). Returns nil immediately
    /// when the annotator is unavailable, so no task is even spawned on CI.
    static func refine(
        using annotator: any AnnotationRefining,
        request: AnnotationRequest,
        timeout: Duration
    ) async -> ModelAnnotation? {
        guard annotator.isAvailable else { return nil }
        return await withTaskGroup(of: ModelAnnotation?.self) { group in
            group.addTask { await annotator.refine(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
