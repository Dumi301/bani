import Foundation
import Security

/// v2.3 open-banking — the ONLY place the Bani WORKER's connection details ever
/// live. The app has no backend of its own beyond that worker: the user enters
/// the worker's base URL + a device token ONCE in Settings and they are written
/// to the iOS **Keychain** (`kSecClassGenericPassword`, this-app-only,
/// `AfterFirstUnlockThisDeviceOnly` so an opportunistic foreground pull works
/// while the phone is locked-after-first-unlock but the item never syncs or
/// leaves the device). There is no minted/refreshed token to cache — the
/// device token IS the bearer credential, sent as-is on every request (the
/// worker owns all upstream Enable Banking auth). Secrets are NEVER written to
/// the repo, `UserDefaults`, a SwiftData `@Model`, a vault file, or a log.
///
/// Everything goes through the `SecretStoring` seam so `EnableBankingClient`
/// and the tests are decoupled from `Security.framework`: CI simulators can be
/// flaky about generic-password items (no keychain-access-group entitlement),
/// so the tests run the round-trip/wipe contract against
/// `InMemorySecretStore` and ALSO attempt the real `KeychainStore`, skipping
/// only if the simulator keychain is genuinely unavailable (see
/// `KeychainStoreTests`).
enum SecretKey: String, Sendable, CaseIterable {
    /// The Bani worker's base URL (e.g. `https://bani-proxy.<account>.workers.dev`).
    case workerBaseURL = "enablebanking.worker_base_url"
    /// The device token sent as `Authorization: Bearer <deviceToken>` on every
    /// worker request (checked against the worker's `DEVICE_TOKENS` secret).
    case deviceToken = "enablebanking.device_token"
}

/// The credential-storage seam. `Sendable` so `EnableBankingClient` (a
/// `Sendable` value) can hold one and be used from any actor. Implementations
/// MUST never log or otherwise externalize a value.
protocol SecretStoring: Sendable {
    func data(for key: SecretKey) -> Data?
    func set(_ data: Data?, for key: SecretKey)
    /// Remove every stored secret (called on Unlink — the wipe-keys contract).
    func wipeAll()
}

extension SecretStoring {
    /// UTF-8 string convenience over the raw-`Data` primitive.
    func string(for key: SecretKey) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: SecretKey) {
        set(value.flatMap { $0.data(using: .utf8) }, for: key)
    }

    /// A `Codable` value convenience, kept for any future structured secret.
    func value<T: Decodable>(_ type: T.Type, for key: SecretKey) -> T? {
        guard let data = data(for: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setValue<T: Encodable>(_ value: T?, for key: SecretKey) {
        guard let value else { set(nil as Data?, for: key); return }
        set(try? JSONEncoder().encode(value), for: key)
    }

    /// Whether both the worker base URL and the device token are present — the
    /// single gate that turns the whole feature on. Either missing ⇒
    /// silent-degrade (feature invisible except its Settings row; sync is inert).
    var hasCredentials: Bool {
        (string(for: .workerBaseURL)?.isEmpty == false) && (string(for: .deviceToken)?.isEmpty == false)
    }
}

/// The production `SecretStoring` — `kSecClassGenericPassword` items under one
/// service, this-app-only, device-only.
struct KeychainStore: SecretStoring {

    /// The service every item is filed under. App-specific; no access group, so
    /// the item is private to this app's keychain and never shared or synced.
    static let service = "com.dumi.bani.gocardless"

    let service: String

    init(service: String = KeychainStore.service) {
        self.service = service
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    func data(for key: SecretKey) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func set(_ data: Data?, for key: SecretKey) {
        // nil clears the item (delete-then-done).
        guard let data else {
            SecItemDelete(baseQuery(for: key) as CFDictionary)
            return
        }
        // Upsert: try update first, insert if the item does not exist yet.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = baseQuery(for: key)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func wipeAll() {
        for key in SecretKey.allCases {
            SecItemDelete(baseQuery(for: key) as CFDictionary)
        }
    }
}

/// An in-process `SecretStoring` for tests (and for any environment where the
/// keychain is unavailable). Thread-safe via a lock — `Sendable` for the same
/// reason `KeychainStore` is.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecretKey: Data] = [:]

    init() {}

    func data(for key: SecretKey) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ data: Data?, for key: SecretKey) {
        lock.lock(); defer { lock.unlock() }
        if let data { storage[key] = data } else { storage[key] = nil }
    }

    func wipeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
