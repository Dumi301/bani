import Foundation
import Observation
import WhisperKit

/// Wraps WhisperKit for on-device speech-to-text. Shared as a single
/// `@Observable` instance injected into the SwiftUI environment by the app
/// root (see `pipeline/interfaces.md` — "Speech — Unit B").
///
/// Model: `openai_whisper-small` (multilingual). Published size ~485 MB —
/// cited from the model card, never measured by forcing a live download.
@MainActor
@Observable
final class WhisperService {
    enum ModelState: Equatable {
        case notReady
        case downloading(progress: Double)   // 0...1
        case ready
        case failed(message: String)
    }

    /// HF `whisperkit-coreml` variant name for the multilingual small model.
    private static let modelVariant = "openai_whisper-small"

    private(set) var modelState: ModelState = .notReady
    let modelSizeMB: Int = 485

    /// A2 forensics: the segment-gate result of the most recent transcription
    /// (kept/dropped counts + drop reasons), surfaced under the Settings
    /// "Last voice session" row. `nil` until the first transcription.
    private(set) var lastSegmentDiagnostics: String?

    /// When `true`, WhisperKit is never touched — used by the UI-test /
    /// manual-only path. `modelState` stays `.notReady` forever and
    /// `transcribe` throws a clear error.
    private let modelAbsent: Bool
    private var pipe: WhisperKit?

    var isModelDownloaded: Bool {
        if case .ready = modelState { return true }
        return false
    }

    init(modelAbsent: Bool = false) {
        self.modelAbsent = modelAbsent
    }

    /// Starts (or continues) the model download + load. Safe to call
    /// repeatedly — a no-op while already `.downloading` or `.ready`.
    /// RESTARTABLE and non-blocking, but NOT byte-resumable: calling this
    /// again after `.failed` restarts the download from scratch (WhisperKit
    /// / the HF Hub deletes partial downloads rather than resuming them).
    func prepareModelIfNeeded() async {
        guard !modelAbsent else { return }
        switch modelState {
        case .ready, .downloading:
            return
        case .notReady, .failed:
            await downloadAndLoad()
        }
    }

    /// Forces a fresh download + load even if a model is already `.ready`.
    /// Backs the "re-download" action in Settings.
    func redownloadModel() async {
        guard !modelAbsent else { return }
        pipe = nil
        modelState = .notReady
        await downloadAndLoad()
    }

    /// Transcribes `audioFileURL`. Diacritics are preserved end-to-end (no
    /// lowercasing / stripping). `DecodingOptions(language: nil,
    /// detectLanguage: true)` is set EXPLICITLY — `language: nil` alone
    /// falls back to English decoding.
    func transcribe(audioFileURL: URL) async throws -> String {
        guard !modelAbsent else { throw WhisperServiceError.modelAbsent }
        guard let pipe else { throw WhisperServiceError.modelNotReady }

        let options = DecodingOptions(language: nil, detectLanguage: true)
        // transcribe(...) returns [TranscriptionResult] — concatenate .text
        // across results rather than assuming a single element.
        let results = try await pipe.transcribe(audioPath: audioFileURL.path, decodeOptions: options)

        // A2: gate on per-segment metadata so background music / ambient noise —
        // which Whisper otherwise transcribes or hallucinates text from — never
        // reaches a saved entry.
        let segments = results.flatMap(\.segments).map {
            SpeechSegment(
                text: $0.text,
                noSpeechProb: $0.noSpeechProb,
                avgLogprob: $0.avgLogprob,
                compressionRatio: $0.compressionRatio
            )
        }

        guard !segments.isEmpty else {
            // No segment metadata to gate on — return the raw text untouched
            // rather than risk dropping a valid transcription.
            lastSegmentDiagnostics = nil
            return results.map(\.text).joined(separator: " ")
        }

        let gate = SegmentGate.filter(segments)
        lastSegmentDiagnostics = gate.diagnostics
        // When every segment is dropped, `keptText` is empty — `runVoicePipeline`
        // then routes to the existing "No speech was detected" path.
        return gate.keptText
    }

    private func downloadAndLoad() async {
        modelState = .downloading(progress: 0)
        do {
            let folder = try await WhisperKit.download(
                variant: Self.modelVariant,
                useBackgroundSession: true,
                // `@Sendable` (nonisolated) for the SAME reason as the Recorder
                // tap block: this closure is formed in a `@MainActor` context
                // but WhisperKit invokes it from a background download queue.
                // Left main-actor-isolated it would hit the identical Swift 6
                // executor trap off the main thread. It only reads a local
                // `Double` and hops to the main actor via `Task { @MainActor }`.
                progressCallback: { @Sendable [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self?.modelState = .downloading(progress: fraction)
                    }
                }
            )
            let config = WhisperKitConfig(
                model: Self.modelVariant,
                modelFolder: folder.path,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
            modelState = .ready
        } catch {
            modelState = .failed(message: error.localizedDescription)
        }
    }
}

/// Errors surfaced by `WhisperService.transcribe` when the model can't be used.
enum WhisperServiceError: LocalizedError {
    case modelAbsent
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelAbsent:
            "Whisper model is unavailable in this build configuration."
        case .modelNotReady:
            "The Whisper model is not ready yet. Wait for the download to finish and try again."
        }
    }
}
