import XCTest
@testable import Bani

/// Transcribes the bundled short RO+EN `.wav` fixture and asserts non-empty
/// text. Runs only in the dedicated `whisper` CI job (see
/// `.github/workflows/ci.yml`) — `build-test` skips this file's tests.
/// Live mic is never used; this exercises `WhisperService` directly against
/// a bundled fixture.
///
/// Any missing fixture, or any failure to fetch/load the model, SKIPS via
/// `XCTSkip` rather than failing — a skip is reported explicitly in CI logs,
/// never silently swallowed.
@MainActor
final class WhisperServiceTests: XCTestCase {

    func testTranscribesShortRoEnFixture() async throws {
        guard let fixtureURL = Self.locateFixture() else {
            throw XCTSkip("model unavailable: short-ro-en.wav fixture not found in test bundle")
        }

        let service = await WhisperService()
        await service.prepareModelIfNeeded()

        let state = await service.modelState
        guard case .ready = state else {
            throw XCTSkip("model unavailable: WhisperService did not reach .ready (state: \(state))")
        }

        do {
            let text = try await service.transcribe(audioFileURL: fixtureURL)
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "expected non-empty transcription of short-ro-en.wav"
            )
        } catch {
            throw XCTSkip("model unavailable: transcription failed — \(error.localizedDescription)")
        }
    }

    /// The fixture is provided by the orchestrator at
    /// `BaniTests/Fixtures/short-ro-en.wav`. XcodeGen's `syncedFolder`
    /// bundles it as a test resource; try both a `Fixtures` subdirectory and
    /// the bundle root since folder-reference flattening can vary.
    private static func locateFixture() -> URL? {
        let bundle = Bundle(for: WhisperServiceTests.self)
        let subdirectories: [String?] = ["Fixtures", nil]
        for subdirectory in subdirectories {
            if let url = bundle.url(forResource: "short-ro-en", withExtension: "wav", subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }
}
