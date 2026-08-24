import XCTest
@testable import Bani

/// P9 — the credential-storage seam. The round-trip / wipe CONTRACT is asserted
/// against `InMemorySecretStore` (deterministic on any CI simulator). The real
/// `KeychainStore` is ALSO exercised, but a generic-password item can be
/// unavailable on a CI simulator with no keychain-access-group entitlement — so
/// that test SKIPS (never fails) when the keychain round-trip does not come back,
/// per the brief's "protocol-seam it and test the seam" instruction.
final class KeychainStoreTests: XCTestCase {

    // MARK: - The seam contract (in-memory, deterministic)

    func testRoundTripStringViaSeam() {
        let store: any SecretStoring = InMemorySecretStore()
        store.set("SECRET_ID_123", for: .secretID)
        store.set("SECRET_KEY_456", for: .secretKey)

        XCTAssertEqual(store.string(for: .secretID), "SECRET_ID_123")
        XCTAssertEqual(store.string(for: .secretKey), "SECRET_KEY_456")
    }

    func testHasCredentialsReflectsBothSecrets() {
        let store: any SecretStoring = InMemorySecretStore()
        XCTAssertFalse(store.hasCredentials)
        store.set("id", for: .secretID)
        XCTAssertFalse(store.hasCredentials, "one secret is not enough")
        store.set("key", for: .secretKey)
        XCTAssertTrue(store.hasCredentials)
    }

    func testCodableValueRoundTrip() {
        let store: any SecretStoring = InMemorySecretStore()
        let bundle = TokenBundle(
            accessToken: "A", accessExpiresAt: Date(timeIntervalSince1970: 1_000_000),
            refreshToken: "R", refreshExpiresAt: Date(timeIntervalSince1970: 2_000_000)
        )
        store.setValue(bundle, for: .tokenBundle)

        let read = store.value(TokenBundle.self, for: .tokenBundle)
        XCTAssertEqual(read, bundle)
    }

    func testWipeAllClearsEverything() {
        let store: any SecretStoring = InMemorySecretStore()
        store.set("id", for: .secretID)
        store.set("key", for: .secretKey)
        store.setValue(TokenBundle(accessToken: "A", accessExpiresAt: .now), for: .tokenBundle)
        XCTAssertTrue(store.hasCredentials)

        store.wipeAll()

        XCTAssertFalse(store.hasCredentials)
        XCTAssertNil(store.string(for: .secretID))
        XCTAssertNil(store.string(for: .secretKey))
        XCTAssertNil(store.value(TokenBundle.self, for: .tokenBundle))
    }

    func testSettingNilClearsASingleKey() {
        let store: any SecretStoring = InMemorySecretStore()
        store.set("id", for: .secretID)
        store.set(nil as String?, for: .secretID)
        XCTAssertNil(store.string(for: .secretID))
    }

    // MARK: - The real KeychainStore (skips if the CI keychain is unavailable)

    func testRealKeychainRoundTripAndWipeOrSkip() throws {
        // Isolate under a unique service so a shared simulator keychain never leaks
        // between runs or tests.
        let store = KeychainStore(service: "com.dumi.bani.gocardless.tests.\(UUID().uuidString)")
        store.wipeAll()

        store.set("REAL_SECRET_ID", for: .secretID)
        guard store.string(for: .secretID) == "REAL_SECRET_ID" else {
            throw XCTSkip("keychain generic-password items are unavailable on this CI simulator — the seam contract is covered by the in-memory tests above")
        }

        // Round-trip proven — now assert update + wipe on the real store.
        store.set("REAL_SECRET_KEY", for: .secretKey)
        XCTAssertEqual(store.string(for: .secretKey), "REAL_SECRET_KEY")
        store.set("REAL_SECRET_ID_UPDATED", for: .secretID)
        XCTAssertEqual(store.string(for: .secretID), "REAL_SECRET_ID_UPDATED", "upsert updates in place")

        store.wipeAll()
        XCTAssertNil(store.string(for: .secretID), "wipe on unlink clears the item")
        XCTAssertNil(store.string(for: .secretKey))
    }
}
