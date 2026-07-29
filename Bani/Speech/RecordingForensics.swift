import AVFoundation

/// Post-recording forensics measured by re-reading the written capture file —
/// the source of truth for the Settings "Last voice session" diagnostics line.
/// Every field is chosen so the row ALONE can discriminate the four voice
/// failure modes behind a "No speech was detected" result:
///
/// - `analyze` returns `nil`               → file missing / unreadable (wrong or
///                                            never-written URL — suspect 3)
/// - duration ≈ 0 · bytes ≈ header · rms 0 → empty file (unclosed/unflushed
///                                            write path — suspect 1)
/// - `sampleRate` not the expected rate    → format mismatch (suspect 2)
/// - short duration but healthy rms        → auto-stop clipped real speech
///                                            (suspect 4)
struct RecordingForensics: Equatable, Sendable {
    var durationSeconds: Double
    var byteSize: Int
    var sampleRate: Double
    var frameCount: Int64
    /// Mean per-block RMS across the file (0…1 linear PCM).
    var averageRMS: Float
    /// Loudest single block's RMS (0…1 linear PCM).
    var peakRMS: Float

    /// One compact, monospaced-friendly line for the Settings diagnostics row.
    var summaryLine: String {
        String(
            format: "%.1fs · %d B · %.0f Hz · rms avg %.3f / peak %.3f",
            durationSeconds, byteSize, sampleRate, averageRMS, peakRMS
        )
    }

    /// Re-opens the finished file and measures it. Reads via `AVAudioFile` — the
    /// same loader WhisperKit uses — so "unreadable here" implies "unreadable by
    /// WhisperKit". Returns `nil` when the file is missing or cannot be opened.
    static func analyze(url: URL) -> RecordingForensics? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = file.length
        let sampleRate = format.sampleRate
        let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0

        // Stream the file in blocks, tracking mean and peak block RMS.
        let blockSize: AVAudioFrameCount = 4096
        var blocks = 0
        var rmsSum: Float = 0
        var peak: Float = 0
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) {
            while true {
                do {
                    try file.read(into: buffer, frameCount: blockSize)
                } catch {
                    break
                }
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }   // EOF
                let rms = blockRMS(buffer: buffer, frameCount: frames)
                rmsSum += rms
                peak = max(peak, rms)
                blocks += 1
            }
        }
        let averageRMS = blocks > 0 ? rmsSum / Float(blocks) : 0

        return RecordingForensics(
            durationSeconds: duration,
            byteSize: byteSize,
            sampleRate: sampleRate,
            frameCount: frameCount,
            averageRMS: averageRMS,
            peakRMS: peak
        )
    }

    private static func blockRMS(buffer: AVAudioPCMBuffer, frameCount: Int) -> Float {
        guard let channelData = buffer.floatChannelData, frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sumOfSquares: Float = 0
        for i in 0..<frameCount {
            sumOfSquares += samples[i] * samples[i]
        }
        return (sumOfSquares / Float(frameCount)).squareRoot()
    }
}
