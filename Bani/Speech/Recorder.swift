@preconcurrency import AVFoundation
import Observation

/// Captures microphone audio to a temp file, auto-stopping after a trailing
/// silence window. Shared, owned by the Log feature (see
/// `pipeline/interfaces.md` — "Speech — Unit B").
@MainActor
@Observable
final class Recorder {
    enum RecordingState: Equatable {
        case idle
        case recording
        case finished(URL)
        case denied
    }

    /// Length of trailing silence that triggers an automatic stop.
    /// `nonisolated` so the real-time render-thread tap can read it without an actor hop.
    nonisolated static let trailingSilenceWindow: TimeInterval = 2.0
    /// RMS amplitude (0...1, linear PCM) below which a buffer is treated as
    /// silence for the purposes of auto-stop.
    /// `nonisolated` so the real-time render-thread tap can read it without an actor hop.
    nonisolated static let silenceRMSThreshold: Float = 0.02

    private(set) var state: RecordingState = .idle
    /// 0...1, drives the waveform.
    private(set) var level: Float = 0
    /// Which capture signal chain the current/last session used (voice-processed
    /// vs. plain-input fallback). Surfaced under Settings → Last voice session so
    /// a degraded route is visible on-device. Set by `beginRecording`.
    private(set) var captureChainNote: String = ""

    private let engine = AVAudioEngine()
    /// Mutated only from the audio engine's real-time render thread —
    /// deliberately kept outside `@MainActor` isolation so the render
    /// callback never has to hop actors to track recording progress.
    private nonisolated(unsafe) let tapState = TapState()

    init() {}

    /// Requests mic permission (if not already determined) and starts
    /// capture immediately. Sets `.recording` on success, `.denied` on
    /// refusal — callers deep-link to Settings on `.denied`.
    func requestPermissionAndStart() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            state = .denied
            return
        }
        do {
            try beginRecording()
            state = .recording
        } catch {
            // Permission was granted but the audio session / engine failed
            // to start (rare — e.g. a competing audio route). Leave the
            // recorder idle so the caller can retry rather than reporting
            // this as a permission denial.
            state = .idle
        }
    }

    /// Manual stop by tap. No-op unless currently recording — auto-stop on
    /// trailing silence routes through the same `finish()` path.
    func stop() {
        guard case .recording = state else { return }
        finish()
    }

    private func beginRecording() throws {
        let session = AVAudioSession.sharedInstance()
        // Voice-oriented session (was `.measurement`, which asks for RAW,
        // unprocessed input and let media playing on the phone bleed into the
        // recording). `.voiceChat` requests the OS voice signal chain.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers])
        try session.setActive(true)

        let input = engine.inputNode

        // A1: turn on iOS voice processing — OS-level echo cancellation + noise
        // suppression. This is what strips media playing from the phone itself
        // (the source of the background-music transcriptions) before Whisper
        // ever sees the audio.
        var usingVoiceProcessing = false
        do {
            try input.setVoiceProcessingEnabled(true)
            usingVoiceProcessing = true
        } catch {
            // Some routes (e.g. certain Bluetooth HFP links) reject voice
            // processing. Degrade to the plain input rather than failing to
            // record at all — noted in the Last voice session row.
            usingVoiceProcessing = false
        }

        do {
            try startCapture(on: input)
        } catch {
            // The voice-processing render chain can itself fail to start on some
            // routes. Tear it down, disable VP, and retry once on plain input so
            // recording still begins.
            guard usingVoiceProcessing else { throw error }
            input.removeTap(onBus: 0)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            usingVoiceProcessing = false
            try startCapture(on: input)
        }

        captureChainNote = usingVoiceProcessing
            ? "voice-processed input (echo cancel + noise suppression)"
            : "plain input — voice processing unavailable on this route"
    }

    /// Opens the capture file in the input node's CURRENT output format and
    /// installs the write tap + starts the engine.
    ///
    /// The format is re-derived HERE — AFTER any `setVoiceProcessingEnabled`
    /// change — on purpose: enabling voice processing changes the input node's
    /// delivered format, and the tap/file settings MUST match the format
    /// actually delivered or the write path decodes as noise. Recording still
    /// happens in the node's native format and is handed to WhisperKit untouched
    /// (its AudioProcessor resamples to 16 kHz mono on load) — no AVAudioConverter.
    private func startCapture(on input: AVAudioInputNode) throws {
        let format = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try Self.makeFile(at: url, format: format)
        tapState.reset(audioFile: file, url: url)

        // The tap block MUST be `@Sendable` (i.e. nonisolated). Without it,
        // this closure — formed here inside `@MainActor`-isolated code and
        // itself non-Sendable — is INFERRED to be `@MainActor`-isolated. AVFAudio
        // then invokes it on its realtime "RealtimeMessenger.mServiceQueue";
        // Swift 6's dynamic executor check (`swift_task_isCurrentExecutor`) sees
        // a non-main executor and the app traps (EXC_BREAKPOINT / SIGTRAP) — the
        // on-device crash. The `@preconcurrency import` only silences the
        // *warning*, it does NOT strip the inherited isolation. `@Sendable` does:
        // the block runs on the audio thread as intended and only calls the
        // already-`nonisolated` `processTap`, which touches locals + `tapState`
        // and hops to the main actor via `Task { @MainActor }`.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// Opens the capture file in the input node's native format. Shared by the
    /// live recording path and the buffer-level test seam so both exercise the
    /// exact same file settings.
    nonisolated static func makeFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// Runs on the audio engine's real-time render thread. Touches only
    /// `tapState` (deliberately non-isolated) and hops to `@MainActor` just
    /// to publish the level / trigger auto-stop.
    private nonisolated func processTap(buffer: AVAudioPCMBuffer) {
        // Commit the buffer to disk synchronously, on this render thread — the
        // write is deliberately NOT hopped to another executor. Only `level`
        // and auto-stop touch `@MainActor` state (below); a hop for the write
        // would let stop()/finish() tear the file down before queued buffers
        // land, producing a near-empty recording.
        tapState.write(buffer)

        let rms = Self.rms(of: buffer)
        let bufferDuration = Double(buffer.frameLength) / buffer.format.sampleRate

        if rms > Self.silenceRMSThreshold {
            tapState.hasDetectedSound = true
            tapState.silenceAccumulated = 0
        } else if tapState.hasDetectedSound {
            // Only accumulate trailing silence AFTER some sound has been
            // heard — otherwise a slow start to speaking would auto-stop
            // the recording before the user says anything.
            tapState.silenceAccumulated += bufferDuration
        }

        let normalizedLevel = min(1, rms * 8)
        let shouldAutoStop = tapState.hasDetectedSound
            && tapState.silenceAccumulated >= Recorder.trailingSilenceWindow

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.level = normalizedLevel
            if shouldAutoStop {
                self.finish()
            }
        }
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sumOfSquares: Float = 0
        for i in 0..<frameCount {
            sumOfSquares += samples[i] * samples[i]
        }
        return (sumOfSquares / Float(frameCount)).squareRoot()
    }

    private func finish() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        level = 0
        // Close/flush the capture file BEFORE publishing its URL. `removeTap`
        // above guarantees no tap callback is mid-write, so finalizing here is
        // race-free. Releasing the AVAudioFile flushes its buffered packets and
        // writes the final RIFF/data chunk sizes into the WAV header — without
        // this the file stayed open until the whole Recorder was deallocated
        // (after transcription had already read it), so WhisperKit saw a
        // ~0-frame header and reported "No speech was detected". Finalize →
        // publish is the fix for that regression.
        if let url = tapState.finalizeFile() {
            state = .finished(url)
        } else {
            state = .idle
        }
    }
}

#if DEBUG
extension Recorder {
    /// Outcome of `recordSynthetic`, consumed by the buffer-level write-path tests.
    struct SyntheticRecordingResult {
        let url: URL
        /// `true` iff the capture file was released (flushed + closed) BEFORE
        /// this result — and therefore the URL — was produced, mirroring
        /// `finish()`'s finalize-then-publish ordering.
        let fileClosedBeforeFinish: Bool
    }

    /// Test seam (CI has no microphone): drives the EXACT production write path
    /// — open via `makeFile`, per-buffer `TapState.write`, then
    /// `TapState.finalizeFile` — over caller-supplied buffers with no
    /// `AVAudioEngine`. Lets tests assert the written file's duration / RMS /
    /// format and the close-before-finish ordering without a live tap.
    nonisolated static func recordSynthetic(
        buffers: [AVAudioPCMBuffer],
        format: AVAudioFormat,
        to url: URL
    ) throws -> SyntheticRecordingResult {
        let file = try makeFile(at: url, format: format)
        let tap = TapState()
        tap.reset(audioFile: file, url: url)
        for buffer in buffers {
            tap.write(buffer)
        }
        let finishedURL = tap.finalizeFile()
        return SyntheticRecordingResult(
            url: finishedURL ?? url,
            fileClosedBeforeFinish: tap.audioFile == nil
        )
    }
}
#endif

/// Mutable recording state touched only from the audio engine's real-time
/// render thread; kept outside `Recorder`'s `@MainActor` isolation on
/// purpose (see `Recorder.tapState`).
private final class TapState: @unchecked Sendable {
    var audioFile: AVAudioFile?
    var recordingURL: URL?
    var silenceAccumulated: TimeInterval = 0
    var hasDetectedSound = false

    func reset(audioFile: AVAudioFile, url: URL) {
        self.audioFile = audioFile
        self.recordingURL = url
        self.silenceAccumulated = 0
        self.hasDetectedSound = false
    }

    /// Commits one buffer to disk. Called synchronously from the audio render
    /// thread — never hopped to another executor (see `processTap`).
    func write(_ buffer: AVAudioPCMBuffer) {
        try? audioFile?.write(from: buffer)
    }

    /// Releases the `AVAudioFile`, which flushes buffered packets and writes the
    /// final WAV header. MUST run before the URL is handed to the transcriber:
    /// a file still held open reports a ~0-frame header, so any reader decodes
    /// silence. Returns the finished file URL.
    func finalizeFile() -> URL? {
        audioFile = nil
        return recordingURL
    }
}
