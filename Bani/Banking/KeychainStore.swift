import Foundation
import Security

/// P9 open-banking — the ONLY place GoCardless credentials ever live. The app has
/// no backend: the user enters `secret_id` / `secret_key` ONCE in Settings and they
/// are written to the iOS **Keychain** (`kSecClassGenericPassword`, this-app-only,
/// `AfterFirstUnlockThisDeviceOnly` so an opportunistic foreground pull works while
/// the phone is locked-after-first-unlock but the item never syncs or leaves the
/// device). The minted access/refresh token is cached here too. Secrets are NEVER
/// written to the repo, `UserDefaults`, a SwiftData `@Model`, a vault file, or a log.
///
/// Everything goes through the `SecretStoring` seam so `GoCardlessClient` and the
/// tests are decoupled from `Security.framework`: CI simulators can be flaky about
/// generic-password items (no keychain-access-group entitlement), so the tests run
/// the round-trip/wipe contract against `InMemorySecretStore` and ALSO attempt the
/// real `KeychainStore`, skipping only if the simulator keychain is genuinely
/// unavailable (see `KeychainStoreTests`).
enum SecretKey: String, Sendable, CaseIterable {
    /// GoCardless `secret_id` (entered by the user).
    case secretID = "gocardless.secret_id"
    /// GoCardless `secret_key` (entered by the user).
    case secretKey = "gocardless.secret_key"
    /// The cached `TokenBundle` (access + refresh + expiries), JSON-encoded.
    case tokenBundle = "gocardless.token_bundle"
}

/// The credential-storage seam. `Sendable` so `GoCardlessClient` (a `Sendable`
/// value) can hold one and be used from any actor. Implementations MUST never log
/// or otherwise externalize a value.
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

    /// A `Codable` value convenience (used for the `TokenBundle`).
    func value<T: Decodable>(_ type: T.Type, for key: SecretKey) -> T? {
        guard let data = data(for: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setValue<T: Encodable>(_ value: T?, for key: SecretKey) {
        guard let value else { set(nil as Data?, for: key); return }
        set(try? JSONEncoder().encode(value), for: key)
    }

    /// Whether both user-entered secrets are present — the single gate that turns
    /// the whole feature on. No secrets ⇒ silent-degrade (feature invisible except
    /// its Settings row; sync is inert).
    var hasCredentials: Bool {
        (string(for: .secretID)?.isEmpty == false) && (string(for: .secretKey)?.isEmpty == false)
    }
}

/// The production `SecretStoring` — `kSecClassGenericPassword` items under one
/// service, this-app-only, device-only.
struct KeychainStore: SecretStoring {

    /// The service every item is filed under. App-specific; no access group, so the
    /// item is private to this app's keychain and never shared or synced.
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
