import XCTest
import AVFoundation
@testable import Bani

/// Buffer-level tests for the recording write path (`Recorder` + `RecordingForensics`).
/// CI has no microphone, so these feed synthetic sine-tone `AVAudioPCMBuffer`s
/// straight through `Recorder.recordSynthetic` — the exact production
/// open → write → finalize path — and assert the written file is a real,
/// readable, non-silent recording that a reader (WhisperKit) would accept.
/// These are the regression guards for the "No speech was detected" bug: an
/// unclosed / unflushed capture file whose WAV header reported ~0 frames.
final class RecorderWritePathTests: XCTestCase {

    /// 48 kHz mono float32, non-interleaved — mirrors the iPhone input node's
    /// native `outputFormat(forBus:)` shape that `Recorder` records in.
    private func nativeFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }

    /// One buffer of a half-scale sine tone at `frequency`, `frameCount` long,
    /// with phase carried across calls so successive buffers are continuous.
    private func sineBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        frequency: Double,
        phase: inout Double
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        let increment = 2.0 * Double.pi * frequency / format.sampleRate
        for i in 0..<Int(frameCount) {
            channel[i] = Float(sin(phase) * 0.5)
            phase += increment
        }
        return buffer
    }

    private func silentBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { channel[i] = 0 }   // explicit silence
        return buffer
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
    }

    // MARK: - Write path produces a real, non-silent, readable file, closed before finish

    func testSyntheticRecordingIsNonSilentReadableAndClosedBeforeFinish() throws {
        let format = nativeFormat()
        let blockFrames: AVAudioFrameCount = 4_800   // 0.1s per buffer @ 48 kHz
        let blocks = 10                              // → ~1.0s total
        var phase = 0.0
        let buffers = (0..<blocks).map { _ in
            sineBuffer(format: format, frameCount: blockFrames, frequency: 440, phase: &phase)
        }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Recorder.recordSynthetic(buffers: buffers, format: format, to: url)

        // Ordering: the capture file was finalized (flushed + closed) BEFORE its
        // URL was produced — the fix for "No speech detected".
        XCTAssertTrue(result.fileClosedBeforeFinish, "file must be closed before its URL is published")

        // Format WhisperKit accepts: the finished file opens via AVAudioFile
        // (the same loader WhisperKit uses) as linear-PCM float.
        let readBack = try XCTUnwrap(try? AVAudioFile(forReading: result.url),
                                     "finished file must open via AVAudioFile")
        XCTAssertEqual(readBack.processingFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertGreaterThan(readBack.length, 0, "header must report the frames actually written")

        let forensics = try XCTUnwrap(RecordingForensics.analyze(url: result.url),
                                      "finished file must be measurable")
        let expected = Double(Int(blockFrames) * blocks) / format.sampleRate
        XCTAssertEqual(forensics.durationSeconds, expected, accuracy: 0.02,
                       "written duration must match the buffers fed in — not a truncated/empty file")
        XCTAssertEqual(forensics.sampleRate, 48_000, accuracy: 1)
        XCTAssertGreaterThan(forensics.byteSize, 1_000, "a real recording dwarfs a bare WAV header")
        XCTAssertGreaterThan(forensics.averageRMS, 0.1, "a 0.5-amplitude sine must read back with clearly non-zero RMS")
        XCTAssertGreaterThanOrEqual(forensics.peakRMS, forensics.averageRMS - 0.001)
    }

    // MARK: - Silent input → non-empty file but zero RMS (discriminates suspect 1/4)

    func testSilentBuffersReadBackAsZeroRMS() throws {
        let format = nativeFormat()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Recorder.recordSynthetic(
            buffers: [silentBuffer(format: format, frameCount: 4_800)],
            format: format,
            to: url
        )
        let forensics = try XCTUnwrap(RecordingForensics.analyze(url: result.url))

        XCTAssertGreaterThan(forensics.durationSeconds, 0.09, "silence is still a non-empty file with real duration")
        XCTAssertEqual(forensics.averageRMS, 0, accuracy: 0.0001, "all-zero samples must measure as zero RMS")
    }

    // MARK: - Missing file → nil forensics (discriminates suspect 3, wrong URL)

    func testAnalyzeReturnsNilForMissingFile() {
        XCTAssertNil(RecordingForensics.analyze(url: tempURL()),
                     "a never-written / wrong URL must surface as nil forensics, not a crash")
    }
}
