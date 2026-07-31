import Foundation
import Observation
import WhisperKit

/// Wraps WhisperKit for on-device speech-to-text. Shared as a single
/// `@Observable` instance injected into the SwiftUI environment by the app
/// root (see `pipeline/interfaces.md` — "Speech — Unit B").
///
/// The transcription model is user-selectable (B): `WhisperModelVariant.small`
/// (~485 MB, default, faster) or `.medium` (~1.5 GB, better Romanian, slower).
/// Both variants coexist on disk; `modelState` always reflects the ACTIVE
/// variant, and a not-yet-downloaded variant behaves exactly like the
/// not-downloaded state (manual entry is unaffected — see B2).
@MainActor
@Observable
final class WhisperService {
    enum ModelState: Equatable {
        case notReady
        case downloading(progress: Double)   // 0...1
        case ready
        case failed(message: String)
    }

    private(set) var modelState: ModelState = .notReady

    /// The active transcription model variant. Persisted (see `persist`) so the
    /// choice survives relaunch; changing it goes through `select(_:)`.
    private(set) var activeVariant: WhisperModelVariant

    /// Published on-disk size of the ACTIVE variant (cited from the model card).
    var modelSizeMB: Int { activeVariant.approxSizeMB }

    /// Forensics for the most recent transcription, surfaced under the Settings
    /// "Last voice session" row (A3). Carries the A1 language decision (detected
    /// language + constrained ro/en probabilities) AND the A2 segment-gate result
    /// (kept/dropped counts + drop reasons). `nil` until the first transcription.
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
        self.activeVariant = WhisperModelVariant.active
    }

    // MARK: - Variant selection (B)

    /// Switches the active variant. Persists the choice, resets state, and — for
    /// a real (non-absent) service — loads the variant from disk if already
    /// downloaded, otherwise starts a fresh download with progress. Until that
    /// completes, `transcribe` throws `modelNotReady` (identical to the plain
    /// not-downloaded state), so manual entry keeps working throughout.
    func select(_ variant: WhisperModelVariant) async {
        guard variant != activeVariant else {
            // Same variant re-selected: ensure it is prepared (no-op if ready).
            await prepareModelIfNeeded()
            return
        }
        activeVariant = variant
        persist(variant)
        pipe = nil
        modelState = .notReady
        await prepareModelIfNeeded()
    }

    // MARK: - Model preparation

    /// Starts (or continues) preparing the ACTIVE variant: loads it from disk if
    /// a previous session already downloaded it, otherwise downloads + loads it.
    /// Safe to call repeatedly — a no-op while already `.downloading` or `.ready`.
    /// RESTARTABLE and non-blocking, but NOT byte-resumable: a download that
    /// `.failed` restarts from scratch (WhisperKit / the HF Hub deletes partials).
    func prepareModelIfNeeded() async {
        guard !modelAbsent else { return }
        switch modelState {
        case .ready, .downloading:
            return
        case .notReady, .failed:
            await loadOrDownload()
        }
    }

    /// Forces a fresh download + load of the ACTIVE variant even if it is already
    /// `.ready`. Backs the "re-download" action in Settings.
    func redownloadModel() async {
        guard !modelAbsent else { return }
        pipe = nil
        setDownloaded(activeVariant, false)
        modelState = .notReady
        await downloadAndLoad()
    }

    // MARK: - Transcription

    /// Transcribes `audioFileURL`. Diacritics are preserved end-to-end (no
    /// lowercasing / stripping).
    ///
    /// A1 — LANGUAGE IS CONSTRAINED to the app's RO/EN world. A non-Auto
    /// `TranscriptionLanguage` Setting forces the decoder outright; Auto runs
    /// WhisperKit's language detector and pins the result to the higher-probability
    /// of {ro, en} (`LanguageConstraint`), so a noisy/short Romanian clip can never
    /// be "transcribed" as Russian. Detection off during decode (`detectLanguage:
    /// false`) keeps the decoder from wandering languages mid-utterance.
    ///
    /// `skipSpecialTokens` keeps decoder tokens (`<|startoftranscript|>`, `<|ro|>`,
    /// …) out of the segment text; the `WhisperTokenStripper` post-process is the
    /// guaranteed backstop.
    func transcribe(audioFileURL: URL) async throws -> String {
        guard !modelAbsent else { throw WhisperServiceError.modelAbsent }
        guard let pipe else { throw WhisperServiceError.modelNotReady }

        // A1: decide the decoder language before transcribing.
        let setting = TranscriptionLanguage.active
        let language: String
        let languageNote: String
        if let forced = setting.forcedCode {
            language = forced
            languageNote = "lang \(forced) (forced)"
        } else {
            do {
                // detectLanguage runs detection only (no full transcription) and
                // returns bare-code probabilities ("ro"/"en"); constrain + argmax.
                let detection = try await pipe.detectLanguage(audioPath: audioFileURL.path)
                language = LanguageConstraint.choose(from: detection.langProbs)
                let pRo = detection.langProbs["ro"].map { String(format: "%.2f", Double($0)) } ?? "—"
                let pEn = detection.langProbs["en"].map { String(format: "%.2f", Double($0)) } ?? "—"
                // A3 forensics: raw detected language (may be a third language!) +
                // the constrained ro/en log-probs that decided the pinned language.
                languageNote = "lang \(language) (det \(detection.language); ro \(pRo)/en \(pEn))"
            } catch {
                // Detector unavailable/failed → floor to the primary language
                // rather than fall through to English-default decoding.
                language = LanguageConstraint.primary
                languageNote = "lang \(LanguageConstraint.primary) (detect failed)"
            }
        }

        var options = DecodingOptions(language: language, detectLanguage: false)
        options.skipSpecialTokens = true
        // transcribe(...) returns [TranscriptionResult] — concatenate .text
        // across results rather than assuming a single element.
        let results = try await pipe.transcribe(audioPath: audioFileURL.path, decodeOptions: options)

        // A2: gate on per-segment metadata so background music / ambient noise —
        // which Whisper otherwise transcribes or hallucinates text from — never
        // reaches a saved entry. Strip decoder tokens BEFORE gating so a
        // token-only segment collapses to empty and is dropped by the gate.
        let segments = results.flatMap(\.segments).map {
            SpeechSegment(
                text: WhisperTokenStripper.strip($0.text),
                noSpeechProb: $0.noSpeechProb,
                avgLogprob: $0.avgLogprob,
                compressionRatio: $0.compressionRatio
            )
        }

        guard !segments.isEmpty else {
            // No segment metadata to gate on — return the raw text untouched
            // (still token-stripped) rather than risk dropping a valid transcription.
            lastSegmentDiagnostics = languageNote
            return WhisperTokenStripper.strip(results.map(\.text).joined(separator: " "))
        }

        let gate = SegmentGate.filter(segments)
        // A3: prepend the language decision to the segment-gate diagnostics so the
        // Settings "Last voice session" row alone shows a corrected misdetection.
        lastSegmentDiagnostics = "\(languageNote) · \(gate.diagnostics)"
        // When every segment is dropped, `keptText` is empty — `runVoicePipeline`
        // then routes to the existing "No speech was detected" path.
        return WhisperTokenStripper.strip(gate.keptText)
    }

    // MARK: - Download / load internals

    /// Loads the active variant from its previously-downloaded folder if present,
    /// otherwise downloads it. A stale "downloaded" flag (cache evicted between
    /// launches) falls through to a fresh download.
    private func loadOrDownload() async {
        if isDownloaded(activeVariant), await loadFromDisk() {
            return
        }
        setDownloaded(activeVariant, false)
        await downloadAndLoad()
    }

    /// Attempts to load the active variant from its recorded on-disk folder with
    /// no network. Returns `false` (leaving `modelState` untouched) if the folder
    /// is gone or the load fails, so the caller can fall back to a download.
    private func loadFromDisk() async -> Bool {
        let variant = activeVariant
        guard let path = UserDefaults.standard.string(forKey: folderKey(variant)),
              FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let config = WhisperKitConfig(
                model: variant.hfVariant,
                modelFolder: path,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
            modelState = .ready
            return true
        } catch {
            pipe = nil
            return false
        }
    }

    private func downloadAndLoad() async {
        modelState = .downloading(progress: 0)
        let variant = activeVariant
        do {
            let folder = try await WhisperKit.download(
                variant: variant.hfVariant,
                useBackgroundSession: true,
                // `@Sendable` (nonisolated) for the SAME reason as the Recorder
                // tap block: this closure is formed in a `@MainActor` context
                // but WhisperKit invokes it from a background download queue.
                // It only reads a local `Double` and hops back to the main actor.
                progressCallback: { @Sendable [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        // Ignore a late callback if the user switched variants mid-download.
                        guard let self, self.activeVariant == variant else { return }
                        self.modelState = .downloading(progress: fraction)
                    }
                }
            )
            // The user may have switched variants while the download ran.
            guard activeVariant == variant else { return }

            let config = WhisperKitConfig(
                model: variant.hfVariant,
                modelFolder: folder.path,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
            modelState = .ready
            UserDefaults.standard.set(folder.path, forKey: folderKey(variant))
            setDownloaded(variant, true)
        } catch {
            guard activeVariant == variant else { return }
            modelState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Per-variant persistence

    private func persist(_ variant: WhisperModelVariant) {
        UserDefaults.standard.set(variant.rawValue, forKey: WhisperModelVariant.storageKey)
    }

    private func folderKey(_ variant: WhisperModelVariant) -> String { "whisper.folder.\(variant.rawValue)" }
    private func downloadedKey(_ variant: WhisperModelVariant) -> String { "whisper.downloaded.\(variant.rawValue)" }

    private func isDownloaded(_ variant: WhisperModelVariant) -> Bool {
        UserDefaults.standard.bool(forKey: downloadedKey(variant))
    }
    private func setDownloaded(_ variant: WhisperModelVariant, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: downloadedKey(variant))
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
