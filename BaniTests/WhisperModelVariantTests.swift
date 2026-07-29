import XCTest
@testable import Bani

/// B — the transcription-model variant: metadata is correct, the default active
/// variant is Small, and selecting a variant persists it (and, with the model
/// absent, never leaves the not-ready state — manual entry stays unaffected).
@MainActor
final class WhisperModelVariantTests: XCTestCase {

    func testVariantMetadata() {
        XCTAssertEqual(WhisperModelVariant.small.hfVariant, "openai_whisper-small")
        XCTAssertEqual(WhisperModelVariant.medium.hfVariant, "openai_whisper-medium")
        XCTAssertEqual(WhisperModelVariant.small.approxSizeMB, 485)
        XCTAssertGreaterThan(WhisperModelVariant.medium.approxSizeMB, WhisperModelVariant.small.approxSizeMB)
        XCTAssertEqual(WhisperModelVariant.small.sizeLabel, "~485 MB")
        XCTAssertEqual(WhisperModelVariant.medium.sizeLabel, "~1.5 GB")
    }

    func testDefaultActiveIsSmall() {
        UserDefaults.standard.removeObject(forKey: WhisperModelVariant.storageKey)
        XCTAssertEqual(WhisperModelVariant.active, .small)
    }

    func testSelectPersistsVariantAndStaysNotReadyWhenModelAbsent() async {
        UserDefaults.standard.removeObject(forKey: WhisperModelVariant.storageKey)

        let service = WhisperService(modelAbsent: true)
        XCTAssertEqual(service.activeVariant, .small)

        await service.select(.medium)

        XCTAssertEqual(service.activeVariant, .medium)
        XCTAssertEqual(UserDefaults.standard.string(forKey: WhisperModelVariant.storageKey), "medium")
        XCTAssertEqual(service.modelState, .notReady, "model absent must never leave the not-ready state")
        XCTAssertEqual(service.modelSizeMB, WhisperModelVariant.medium.approxSizeMB)

        UserDefaults.standard.removeObject(forKey: WhisperModelVariant.storageKey)
    }
}
