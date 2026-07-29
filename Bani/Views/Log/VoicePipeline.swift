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
    var transcript: String
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

/// Runs the voice pipeline with injectable `transcribe` / `parse` so the real
/// UI path and the unit tests exercise the SAME decision logic. Never throws:
/// a transcription failure is folded into `errorMessage`, never a dropped flow.
@MainActor
func runVoicePipeline(
    audioFileURL: URL,
    transcribe: @MainActor (URL) async throws -> String,
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
            errorMessage: error.localizedDescription
        )
    }

    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        // Empty/whitespace transcript is a failure too — surface it.
        return VoicePipelineResult(
            parsed: ParsedTransaction(amount: nil, descriptionText: ""),
            transcript: transcript,
            errorMessage: VoicePipelineResult.emptyTranscriptMessage
        )
    }

    let parsed = await parse(transcript)
    // A non-empty transcript is a success even when no amount was found: the
    // card opens in edit mode with the transcript visible (handled downstream).
    return VoicePipelineResult(parsed: parsed, transcript: transcript, errorMessage: nil)
}

/// Records the outcome of the most recent voice attempt to `@AppStorage` so the
/// Settings "Last voice session" row can surface it on-device (A3). One key,
/// permanent-cheap, updated on every voice attempt.
enum VoiceSessionLog {
    static let appStorageKey = "lastVoiceSession"

    static func record(_ result: VoicePipelineResult) {
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
    }
}
