import Foundation

/// The outcome of the voice pipeline (transcribe → parse), decoupled from any
/// SwiftUI state so the `A2` contracts can be unit-tested directly.
///
/// Contract (see `pipeline/spec.md` — "never invent a number, never silently
/// drop"):
/// - transcribe threw           → `errorMessage != nil`, `parsed.amount == nil`
/// - transcribe empty/whitespace → `errorMessage != nil`, `parsed.amount == nil`
/// - non-empty transcript, no amount → `errorMessage == nil`, `parsed.amount == nil`
///                                       (`transcript` kept verbatim for the card)
/// - non-empty transcript, amount   → `errorMessage == nil`, `parsed.amount != nil`
///
/// In every case the `ConfirmationCard` STAYS OPEN — it is never dismissed
/// without a persisted `Transaction` or an explicit user swipe.
struct VoicePipelineResult: Equatable, Sendable {
    var parsed: ParsedTransaction
    /// The TRUE raw Whisper transcript, verbatim — persisted as
    /// `Transaction.rawTranscript` and shown as "Heard". Never refined.
    var transcript: String
    /// The refined transcript (A1) the parser/categorizer actually consumed and
    /// the description is derived from. Equals `transcript` when the rule-based
    /// refiner found nothing to clean. Empty on a transcription failure.
    var cleanText: String = ""
    /// Non-nil when transcription failed or produced nothing usable. Carries
    /// the raw underlying message so the card can surface it for device
    /// debugging; `nil` on a normal (even amount-less) transcript.
    var errorMessage: String?

    /// Friendly headline shown on the card when `errorMessage != nil`.
    static let errorHeadline = "Transcription failed — type it?"
    /// Synthesized message for the "recording produced no speech" case, where
    /// nothing was thrown but the transcript is empty/whitespace.
    static let emptyTranscriptMessage = "No speech was detected in the recording."

    /// The card opens in edit mode when there is no amount to confirm OR there
    /// is an error the user must resolve. Pure derivation — `ConfirmationCard`'s
    /// init and the A2 tests both call `shouldOpenInEditMode(parsedAmount:errorMessage:)`.
    var opensInEditMode: Bool {
        Self.shouldOpenInEditMode(parsedAmount: parsed.amount, errorMessage: errorMessage)
    }

    /// Whether the card must show the transcription-error line.
    var signalsError: Bool { errorMessage != nil }

    static func shouldOpenInEditMode(parsedAmount: Decimal?, errorMessage: String?) -> Bool {
        parsedAmount == nil || errorMessage != nil
    }
}

/// Runs the voice pipeline with injectable `transcribe` / `refine` / `parse` so
/// the real UI path and the unit tests exercise the SAME decision logic. Never
/// throws: a transcription failure is folded into `errorMessage`, never a dropped
/// flow. The refiner (A1) is the new stage between transcription and parsing —
/// `transcript` stays the TRUE raw output, `cleanText` is what the parser sees.
/// `refine` defaults to the deterministic rule-based refiner (the CI path).
@MainActor
func runVoicePipeline(
    audioFileURL: URL,
    transcribe: @MainActor (URL) async throws -> String,
    refine: (String) async -> RefinedTranscript = { await RuleBasedRefiner().refine($0) },
    parse: @MainActor (String) async -> ParsedTransaction
) async -> VoicePipelineResult {
    let transcript: String
    do {
        transcript = try await transcribe(audioFileURL)
    } catch {
        // transcribe() threw → keep the card open in edit mode with the raw
        // error; never invent an amount, never silently drop.
        return VoicePipelineResult(
            parsed: ParsedTransaction(amount: nil, descriptionText: ""),
            transcript: "",
            cleanText: "",
            errorMessage: error.localizedDescription
        )
    }

    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        // Empty/whitespace transcript is a failure too — surface it.
        return VoicePipelineResult(
            parsed: ParsedTransaction(amount: nil, descriptionText: ""),
            transcript: transcript,
            cleanText: "",
            errorMessage: VoicePipelineResult.emptyTranscriptMessage
        )
    }

    // A1: clean the raw transcript before parsing. If refinement leaves nothing
    // meaningful (recording was only non-speech artifacts), route to the SAME
    // no-speech error path — never a blank card, never an invented amount.
    let refined = await refine(transcript)
    guard refined.hadContent else {
        return VoicePipelineResult(
            parsed: ParsedTransaction(amount: nil, descriptionText: ""),
            transcript: transcript,
            cleanText: refined.cleanText,
            errorMessage: VoicePipelineResult.emptyTranscriptMessage
        )
    }

    let parsed = await parse(refined.cleanText)
    // A non-empty transcript is a success even when no amount was found: the
    // card opens in edit mode with the transcript visible (handled downstream).
    return VoicePipelineResult(
        parsed: parsed,
        transcript: transcript,
        cleanText: refined.cleanText,
        errorMessage: nil
    )
}

/// Records the outcome of the most recent voice attempt to `@AppStorage` so the
/// Settings "Last voice session" row can surface it on-device (A3). One key,
/// permanent-cheap, updated on every voice attempt.
enum VoiceSessionLog {
    static let appStorageKey = "lastVoiceSession"
    /// Companion key holding the recording-forensics line (duration, bytes,
    /// sample rate, avg/peak RMS) surfaced under the same Settings row. Kept
    /// separate from `appStorageKey` so the transcript summary and the file
    /// diagnostics render as two independent lines.
    static let forensicsKey = "lastVoiceForensics"
    /// Key holding the A1 refinement pair — raw AND refined side by side — so the
    /// Settings "Last voice session" row shows exactly what the refiner changed.
    /// Empty when the refiner left the transcript untouched (nothing to show).
    static let refinementKey = "lastVoiceRefinement"

    /// `captureNote` is the recording signal chain (A1 — voice-processed vs.
    /// plain-input fallback); `segmentDiagnostics` is the A2 segment-gate result
    /// (kept/dropped counts + drop reasons). Both are appended to the forensics
    /// row so a single line discriminates a degraded route or gated-out audio.
    static func record(
        _ result: VoicePipelineResult,
        audioFileURL: URL?,
        captureNote: String? = nil,
        segmentDiagnostics: String? = nil
    ) {
        let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String
        if let error = result.errorMessage {
            let quoted = transcript.isEmpty ? "(no transcript)" : "“\(transcript)”"
            summary = "⚠︎ \(error) · \(quoted)"
        } else if let amount = result.parsed.amount {
            summary = "“\(transcript)” → \(amount) \(result.parsed.currency.displayCode)"
        } else {
            summary = "“\(transcript)” → no amount found"
        }
        UserDefaults.standard.set(summary, forKey: appStorageKey)

        // A3 forensics: re-measure the written file so the row alone can tell an
        // empty / mis-formatted / clipped recording apart from a genuine "user
        // said nothing". `analyze` returns nil when the file is missing or
        // unreadable — itself a diagnostic (a wrong or never-written URL).
        var forensicsLine = audioFileURL
            .flatMap(RecordingForensics.analyze(url:))?
            .summaryLine ?? "no readable recording file"
        if let captureNote, !captureNote.isEmpty { forensicsLine += " · \(captureNote)" }
        if let segmentDiagnostics, !segmentDiagnostics.isEmpty { forensicsLine += " · \(segmentDiagnostics)" }
        UserDefaults.standard.set(forensicsLine, forKey: forensicsKey)

        // A1/A2: raw AND refined, side by side — only when the refiner actually
        // changed something, so an untouched transcript doesn't show a redundant
        // duplicate line. Diacritics/numbers are preserved verbatim by the refiner.
        let clean = result.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, clean != transcript {
            UserDefaults.standard.set("raw “\(transcript)” → refined “\(clean)”", forKey: refinementKey)
        } else {
            UserDefaults.standard.set("", forKey: refinementKey)
        }
    }
}
