import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence query compiler (iOS 26 Foundation Models) — the
/// FM implementation of `QueryCompiling` for P11. Availability-gated on
/// `SystemLanguageModel.default.availability`; every other path —
/// unavailability, `FoundationModels` not importable on the building SDK, any
/// thrown error, or a proposal with nothing usable — **silently returns nil**,
/// deferring to the raw keyword-search fallback. Never throws, never crashes.
///
/// It only PROPOSES: `QueryCompiler` verifies every project/person/custom-category
/// name against the live registry and drops anything that does not exist, and
/// resolves every relative-date TOKEN (never a raw date) against an injected
/// `now` + `Calendar`. Follows the exact conventions of `FoundationModelsAnnotator`
/// (P10) — same gating + silent fallback + `@Generable` structured output; no
/// second FM entry pattern.
struct FoundationModelsQueryCompiler: QueryCompiling {
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    func compile(_ request: SearchQueryRequest) async -> SearchQueryProposal? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions(request))
            let response = try await session.respond(
                to: String(request.query.prefix(500)),
                generating: SearchQueryExtraction.self
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
    private static func instructions(_ request: SearchQueryRequest) -> String {
        let projects = request.knownProjects.isEmpty ? "(none)" : request.knownProjects.joined(separator: ", ")
        let people = request.knownPeople.isEmpty ? "(none)" : request.knownPeople.joined(separator: ", ")
        let customCategories = request.knownCustomCategories.isEmpty ? "(none)" : request.knownCustomCategories.joined(separator: ", ")
        return """
        You compile a short Romanian or English natural-language search query \
        over a personal finance transaction history into structured fields. You \
        NEVER invent facts — leave a field empty unless the query clearly supports it.

        Extract, when clear:
        - relativeDate: a date phrase like "last spring" / "luna trecută" / "în \
        aprilie", classified into ONE of the given tokens. NEVER compute an actual \
        date yourself — only classify the phrase.
        - amountMin / amountMax: a one- or two-sided amount bound ("over 500", \
        "under 100", "between 200 and 500"), as a plain digit string, no currency symbol.
        - exactAmount: a single specific amount mentioned ("the 1200 lei payment"), as a plain digit string.
        - currency: "RON" or "EUR" if explicit, else empty.
        - direction: "income" for money received, "expense" for money spent, \
        "neutral" for a transfer, else empty.
        - presetCategory: the spending category, if clear.
        - customCategoryName: ONLY a name from this list of the user's real custom \
        categories, matched verbatim; otherwise leave it empty. Real custom categories: \(customCategories).
        - projectName: ONLY a name from this list of the user's real projects, \
        matched verbatim; otherwise leave it empty. Real projects: \(projects).
        - personName: prefer a name from this list of known people/counterparties, \
        matched verbatim: \(people). If the query clearly names someone not on the \
        list, you may still return that name, but never guess one not in the text.
        - remainderText: whatever meaningful search text is left after removing the \
        above (e.g. a merchant, item, or keyword), else empty.
        """
    }

    /// Maps the model's structured output into a `SearchQueryProposal`; empty
    /// strings become nil ("no opinion"). Returns nil only when the model
    /// proposed nothing at all.
    private static func map(_ extracted: SearchQueryExtraction) -> SearchQueryProposal? {
        let relativeDate = RelativeDateToken(rawValue: normalize(extracted.relativeDate))
        let amountMin = decimal(extracted.amountMin)
        let amountMax = decimal(extracted.amountMax)
        let exactAmount = decimal(extracted.exactAmount)
        let currency = Currency(rawValue: extracted.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        let direction = TransactionDirection(rawValue: normalize(extracted.direction))
        let presetCategory = TransactionCategory(rawValue: normalize(extracted.presetCategory))
        let customCategoryName = nonEmpty(extracted.customCategoryName)
        let projectName = nonEmpty(extracted.projectName)
        let personName = nonEmpty(extracted.personName)
        let remainderText = nonEmpty(extracted.remainderText)

        let proposal = SearchQueryProposal(
            relativeDate: relativeDate, amountMin: amountMin, amountMax: amountMax, exactAmount: exactAmount,
            currency: currency, direction: direction, presetCategory: presetCategory,
            customCategoryName: customCategoryName, projectName: projectName, personName: personName,
            remainderText: remainderText
        )
        return proposal.isEmpty ? nil : proposal
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Money is NEVER `Double` — parsed straight into `Decimal` from the model's
    /// plain digit string.
    private static func decimal(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed)
    }
    #endif
}

#if canImport(FoundationModels)
/// Structured extraction target for the query-compiling seam. All-`String`
/// (safe for `@Generable`); the enum-valued fields are constrained with
/// `.anyOf` including an empty option so the model can decline. Money is
/// extracted as plain digit strings here — the surface owns the `Decimal`
/// conversion (`map`), never a `Double`.
@Generable
private struct SearchQueryExtraction {
    @Guide(description: "A relative date phrase classified into one token, or empty.", .anyOf([
        "today", "yesterday", "thisWeek", "lastWeek", "thisMonth", "lastMonth",
        "thisYear", "lastYear", "thisSpring", "lastSpring", "thisSummer", "lastSummer",
        "thisFall", "lastFall", "thisWinter", "lastWinter",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", ""
    ]))
    var relativeDate: String

    @Guide(description: "A lower amount bound as a plain digit string, or empty.")
    var amountMin: String

    @Guide(description: "An upper amount bound as a plain digit string, or empty.")
    var amountMax: String

    @Guide(description: "A single exact amount mentioned, as a plain digit string, or empty.")
    var exactAmount: String

    @Guide(description: "The currency, or empty if unclear.", .anyOf(["RON", "EUR", ""]))
    var currency: String

    @Guide(description: "Money direction, or empty if unclear.", .anyOf(["income", "expense", "neutral", ""]))
    var direction: String

    @Guide(description: "Spending category, or empty if unclear.", .anyOf([
        "fuel", "groceries", "dining", "transport", "utilities",
        "shopping", "health", "entertainment", "other", ""
    ]))
    var presetCategory: String

    @Guide(description: "The referenced real custom-category name, matched verbatim from the provided list, or empty.")
    var customCategoryName: String

    @Guide(description: "The referenced real project name, matched verbatim from the provided list, or empty.")
    var projectName: String

    @Guide(description: "The other party (person/company), only if named in the query, or empty.")
    var personName: String

    @Guide(description: "Whatever meaningful search text remains, or empty.")
    var remainderText: String
}
#endif
