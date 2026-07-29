import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence transcript refiner (iOS 26 Foundation Models),
/// mirroring `FoundationModelsParser`'s availability-selection contract exactly.
///
/// Availability-gated on `SystemLanguageModel.default.availability`: only proceeds
/// when `.available`. Every other path — unavailability, `FoundationModels` not
/// importable on the building SDK, any thrown error, or the model returning
/// nothing usable — **silently falls back** to `fallback.refine(raw)`. This type
/// never throws and never crashes; `refine` always returns a value.
///
/// The instructions are deliberately conservative: rewrite into ONE clean expense
/// phrase, merge pause fragments, drop non-speech artifacts, fix stray
/// punctuation, keep the language (Romanian stays Romanian), keep ALL numbers
/// verbatim, keep diacritics, and invent NOTHING.
struct FoundationModelsRefiner: TranscriptRefiner {
    private let fallback: any TranscriptRefiner

    init(fallback: any TranscriptRefiner) {
        self.fallback = fallback
    }

    func refine(_ raw: String) async -> RefinedTranscript {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            return await fallback.refine(raw)
        }

        do {
            let session = LanguageModelSession(
                instructions: """
                You clean up a raw speech-to-text transcript of someone logging a \
                single expense out loud. The transcript may be in Romanian or \
                English, or mix the two, and it may be broken into fragments by \
                pauses or speckled with non-speech noise.

                Rewrite it into ONE clean, natural expense phrase. Rules:
                - Merge fragments split by pauses into a single phrase (e.g. \
                "cazare. mare." becomes "cazare mare").
                - Remove non-speech artifacts and annotations such as "[music]", \
                "[blank audio]", "(muzică)", "(background noise)".
                - Fix stray or fragment-splitting punctuation.
                - Keep the original language — Romanian stays Romanian, do not \
                translate.
                - Preserve Romanian diacritics (ă, â, î, ș, ț) exactly.
                - Keep EVERY number exactly as spoken, including decimal separators \
                (e.g. "12,50" stays "12,50"). Never change, drop, or add a number.
                - Invent NOTHING. Only remove noise and merge fragments; never add \
                words that were not spoken.

                Set hasMeaningfulContent to false and leave cleanedPhrase empty when \
                nothing meaningful remains (the transcript was only noise, \
                annotations, or silence).
                """
            )

            let response = try await session.respond(
                to: raw,
                generating: RefinedExpensePhrase.self
            )

            guard let refined = Self.map(response.content) else {
                return await fallback.refine(raw)
            }
            return refined
        } catch {
            return await fallback.refine(raw)
        }
        #else
        return await fallback.refine(raw)
        #endif
    }

    #if canImport(FoundationModels)
    /// Maps the model's structured output into `RefinedTranscript`. Returns `nil`
    /// (→ caller falls back to the rule-based refiner) only when the model both
    /// flagged the phrase meaningful AND returned an empty string — a
    /// self-contradiction we don't trust; the deterministic refiner decides
    /// instead.
    private static func map(_ generated: RefinedExpensePhrase) -> RefinedTranscript? {
        let cleaned = generated.cleanedPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !generated.hasMeaningfulContent {
            // Model says nothing meaningful — honor it (routes to no-speech path).
            return RefinedTranscript(cleanText: "", hadContent: false)
        }
        guard !cleaned.isEmpty else { return nil }
        return RefinedTranscript(cleanText: cleaned, hadContent: true)
    }
    #endif
}

#if canImport(FoundationModels)
/// Structured refinement target for `LanguageModelSession.respond(to:generating:)`.
@Generable
private struct RefinedExpensePhrase {
    @Guide(description: "The transcript rewritten as one clean expense phrase, same language, all numbers and diacritics preserved verbatim, nothing invented. Empty when nothing meaningful remains.")
    var cleanedPhrase: String

    @Guide(description: "True when the transcript contained a real spoken expense note; false when it was only noise, non-speech annotations, or silence.")
    var hasMeaningfulContent: Bool
}
#endif
