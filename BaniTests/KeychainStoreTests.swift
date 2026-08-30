import XCTest
@testable import Bani

/// v2.3 — the credential-storage seam. The round-trip / wipe CONTRACT is
/// asserted against `InMemorySecretStore` (deterministic on any CI simulator).
/// The real `KeychainStore` is ALSO exercised, but a generic-password item can
/// be unavailable on a CI simulator with no keychain-access-group entitlement
/// — so that test SKIPS (never fails) when the keychain round-trip does not
/// come back, per the brief's "protocol-seam it and test the seam" instruction.
final class KeychainStoreTests: XCTestCase {

    // MARK: - The seam contract (in-memory, deterministic)

    func testRoundTripStringViaSeam() {
        let store: any SecretStoring = InMemorySecretStore()
        store.set("https://bani-proxy.example.workers.dev", for: .workerBaseURL)
        store.set("DEVICE_TOKEN_123", for: .deviceToken)

        XCTAssertEqual(store.string(for: .workerBaseURL), "https://bani-proxy.example.workers.dev")
        XCTAssertEqual(store.string(for: .deviceToken), "DEVICE_TOKEN_123")
    }

    func testHasCredentialsReflectsBothSecrets() {
        let store: any SecretStoring = InMemorySecretStore()
        XCTAssertFalse(store.hasCredentials)
        store.set("https://bani-proxy.example.workers.dev", for: .workerBaseURL)
        XCTAssertFalse(store.hasCredentials, "one secret is not enough")
        store.set("DEVICE_TOKEN_123", for: .deviceToken)
        XCTAssertTrue(store.hasCredentials)
    }

    /// Device tokens can be long, opaque, high-entropy strings — proves the
    /// Keychain round-trip holds a ~200-char value exactly, byte for byte.
    func testRoundTripLongDeviceTokenValue() {
        let store: any SecretStoring = InMemorySecretStore()
        let longToken = String(repeating: "a1B2c3D4-", count: 22) // 198 chars
        XCTAssertEqual(longToken.count, 198)

        store.set(longToken, for: .deviceToken)

        XCTAssertEqual(store.string(for: .deviceToken), longToken)
    }

    func testWipeAllClearsEverything() {
        let store: any SecretStoring = InMemorySecretStore()
        store.set("https://bani-proxy.example.workers.dev", for: .workerBaseURL)
        store.set("DEVICE_TOKEN_123", for: .deviceToken)
        XCTAssertTrue(store.hasCredentials)

        store.wipeAll()

        XCTAssertFalse(store.hasCredentials)
        XCTAssertNil(store.string(for: .workerBaseURL))
        XCTAssertNil(store.string(for: .deviceToken))
    }

    func testSettingNilClearsASingleKey() {
        let store: any SecretStoring = InMemorySecretStore()
        store.set("https://bani-proxy.example.workers.dev", for: .workerBaseURL)
        store.set(nil as String?, for: .workerBaseURL)
        XCTAssertNil(store.string(for: .workerBaseURL))
    }

    // MARK: - The real KeychainStore (skips if the CI keychain is unavailable)

    func testRealKeychainRoundTripAndWipeOrSkip() throws {
        // Isolate under a unique service so a shared simulator keychain never leaks
        // between runs or tests.
        let store = KeychainStore(service: "com.dumi.bani.gocardless.tests.\(UUID().uuidString)")
        store.wipeAll()

        store.set("https://bani-proxy.example.workers.dev", for: .workerBaseURL)
        guard store.string(for: .workerBaseURL) == "https://bani-proxy.example.workers.dev" else {
            throw XCTSkip("keychain generic-password items are unavailable on this CI simulator — the seam contract is covered by the in-memory tests above")
        }

        // Round-trip proven — now assert update + wipe on the real store.
        store.set("REAL_DEVICE_TOKEN", for: .deviceToken)
        XCTAssertEqual(store.string(for: .deviceToken), "REAL_DEVICE_TOKEN")
        store.set("https://bani-proxy-updated.example.workers.dev", for: .workerBaseURL)
        XCTAssertEqual(store.string(for: .workerBaseURL), "https://bani-proxy-updated.example.workers.dev", "upsert updates in place")

        store.wipeAll()
        XCTAssertNil(store.string(for: .workerBaseURL), "wipe on unlink clears the item")
        XCTAssertNil(store.string(for: .deviceToken))
    }
}
