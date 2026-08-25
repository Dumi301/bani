import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence annotator (iOS 26 Foundation Models) — the FM
/// implementation of `AnnotationRefining` for P10. Availability-gated on
/// `SystemLanguageModel.default.availability`; every other path — unavailability,
/// `FoundationModels` not importable on the building SDK, any thrown error, or a
/// proposal with nothing usable — **silently returns nil**, deferring to the
/// deterministic interpretation. Never throws, never crashes.
///
/// It only PROPOSES: `InterpretationService` verifies every project/counterparty
/// name against the live registry and drops anything that does not exist, so the
/// model can never inject a hallucinated target. Follows the exact conventions of
/// `FoundationModelsParser` / `FoundationModelsExtractor` (same gating + silent
/// fallback + `@Generable` structured output; no invented FM API shapes).
struct FoundationModelsAnnotator: AnnotationRefining {
    /// Confidence assigned to any concrete FM proposal — deliberately below a
    /// learned rule (0.9) so a remembered user correction always wins, and above
    /// the pre-fill threshold (0.5) so a confident model suggestion pre-fills.
    static let modelConfidence = 0.7

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    func refine(_ request: AnnotationRequest) async -> ModelAnnotation? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions(request))
            let response = try await session.respond(
                to: String(request.text.prefix(2000)),
                generating: AnnotationExtraction.self
            )
            return Self.map(response.content)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    private static func instructions(_ request: AnnotationRequest) -> String {
        let projects = request.knownProjects.isEmpty
            ? "(none)"
            : request.knownProjects.joined(separator: ", ")
        let people = request.knownPeople.isEmpty
            ? "(none)"
            : request.knownPeople.joined(separator: ", ")
        return """
        You annotate a short Romanian or English note about a single financial \
        transaction. Preserve Romanian diacritics (ă, â, î, ș, ț) verbatim. You \
        NEVER invent facts — leave a field empty unless the note clearly supports it.

        Assign, when clear:
        - category: the spending category.
        - projectName: the business project this refers to. Use ONLY a name from \
        this list of the user's real projects, matched verbatim; otherwise leave it \
        empty. Real projects: \(projects).
        - counterparty: the other party (a person or company). Prefer a name from \
        this list of known people, matched verbatim: \(people). If the note clearly \
        names someone not on the list, you may still return that name, but never \
        guess one that is not in the text.
        - direction: "income" for money received, "expense" for money spent, \
        "neutral" for a transfer / cash move / loan. Leave empty if unclear.
        """
    }

    /// Maps the model's structured output into a `ModelAnnotation`; empty strings
    /// become nil ("no opinion"). Returns nil only when the model proposed nothing.
    private static func map(_ extracted: AnnotationExtraction) -> ModelAnnotation? {
        let category = TransactionCategory(rawValue: normalize(extracted.category))
        let direction = TransactionDirection(rawValue: normalize(extracted.direction))
        let projectName = nonEmpty(extracted.projectName)
        let counterparty = nonEmpty(extracted.counterparty)

        guard category != nil || direction != nil || projectName != nil || counterparty != nil else {
            return nil
        }
        return ModelAnnotation(
            category: category,
            projectName: projectName,
            counterparty: counterparty,
            direction: direction,
            confidence: modelConfidence
        )
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif
}

#if canImport(FoundationModels)
/// Structured extraction target for the annotation seam. All-`String` (safe for
/// `@Generable`); the enum-valued fields are constrained with `.anyOf` including
/// an empty option so the model can decline. Money is NEVER extracted here — the
/// surface's own parser owns the `Decimal` amount.
@Generable
private struct AnnotationExtraction {
    @Guide(description: "Spending category, or empty if unclear.", .anyOf([
        "fuel", "groceries", "dining", "transport", "utilities",
        "shopping", "health", "entertainment", "other", ""
    ]))
    var category: String

    @Guide(description: "The referenced real project name, matched verbatim from the provided list, or empty.")
    var projectName: String

    @Guide(description: "The other party (person/company), only if named in the note, or empty.")
    var counterparty: String

    @Guide(description: "Money direction, or empty if unclear.", .anyOf(["income", "expense", "neutral", ""]))
    var direction: String
}
#endif
