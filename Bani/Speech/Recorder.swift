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
    static let trailingSilenceWindow: TimeInterval = 2.0
    /// RMS amplitude (0...1, linear PCM) below which a buffer is treated as
    /// silence for the purposes of auto-stop.
    static let silenceRMSThreshold: Float = 0.02

    private(set) var state: RecordingState = .idle
    /// 0...1, drives the waveform.
    private(set) var level: Float = 0

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
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        tapState.reset(audioFile: file, url: url)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// Runs on the audio engine's real-time render thread. Touches only
    /// `tapState` (deliberately non-isolated) and hops to `@MainActor` just
    /// to publish the level / trigger auto-stop.
    private nonisolated func processTap(buffer: AVAudioPCMBuffer) {
        try? tapState.audioFile?.write(from: buffer)

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
        if let url = tapState.recordingURL {
            state = .finished(url)
        } else {
            state = .idle
        }
    }
}

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
}
