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
        return results.map(\.text).joined(separator: " ")
    }

    private func downloadAndLoad() async {
        modelState = .downloading(progress: 0)
        do {
            let folder = try await WhisperKit.download(
                variant: Self.modelVariant,
                useBackgroundSession: true,
                progressCallback: { [weak self] progress in
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
