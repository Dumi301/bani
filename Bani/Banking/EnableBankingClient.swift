import Foundation

/// v2.3 — the pure REST client for the Bani WORKER (a Cloudflare Worker that
/// proxies Enable Banking's Open Banking API, see `pipeline/prompts-v2.3/contract.md`).
/// NO SDK, NO backend-of-its-own on the app side: raw `URLRequest`/`URLSession`
/// against the worker's documented pass-through endpoints, mirroring
/// `RateService`'s conventions — one injectable network seam (`HTTPSession`,
/// defaulting to `URLSession.shared`) so every path is exercised on CI against
/// recorded fixtures with NO live network and NO keys, and every failure is a
/// thrown `EnableBankingError` the caller can silently absorb (the RateService
/// "network failure is silent" rule).
///
/// Auth is a single static bearer: every request sends
/// `Authorization: Bearer <deviceToken>`, read fresh from the Keychain each
/// time. There is NO JWT minting, NO refresh, NO 401-retry dance here — the
/// worker owns the upstream Enable Banking RS256 JWT entirely. A 401 FROM THE
/// WORKER means the device token itself is wrong/revoked; it surfaces as
/// `.unauthorized` for the caller to react to (e.g. prompt re-entry in
/// Settings) and is never retried.
///
/// The client is a `Sendable` value: it owns no mutable state. Both the
/// worker's base URL and the device token live in the Keychain via
/// `SecretStoring`, so concurrent calls stay correct and nothing secret is
/// ever held in memory longer than a request.
///
/// Decoding is TOLERANT throughout: bank feeds vary enormously between
/// institutions, so every response field the app does not strictly require is
/// optional and a missing/extra field never throws (proven by the
/// missing-optional-fields test). Amounts arrive as STRINGS and STAY strings —
/// parsing to `Decimal` and resolving sign from `credit_debit_indicator` is
/// Phase 2's job (`BankSyncMapper`), never `Double`.

// MARK: - Network seam

/// The one-method network seam (mirrors `URLSession.data(for:)`). Injectable so
/// tests feed recorded fixtures; production uses `URLSession.shared`.
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

// MARK: - Errors

/// Every failure mode, tolerant by design — the caller (BankSyncService / the
/// Settings view) turns any of these into a silent retry/backoff, never a
/// crash and never a blocking alert.
enum EnableBankingError: Error, Equatable {
    /// No worker base URL / device token configured yet — the feature is inert.
    case noCredentials
    /// A non-2xx HTTP status from the worker (carries the code + raw body — the
    /// worker relays Enable Banking's own errors verbatim, so `body` is often
    /// EB's real error JSON, useful for debugging without a reshape).
    case http(status: Int, body: String)
    /// The worker rejected the device token (401) — bad/revoked token, never
    /// retried here.
    case unauthorized
    /// The body could not be decoded into the expected shape.
    case decoding
    /// A transport-level failure (offline, DNS, timeout, …).
    case transport
}

// MARK: - DTOs (tolerant, optional-heavy, snake_case CodingKeys matching EB JSON)

/// GET /aspsps element — a bank ("ASPSP" in PSD2 terminology) available in a
/// country. `maximum_consent_validity` arrives as either an Int or a Double
/// across ASPSPs — decoded tolerantly (never throws on either shape).
struct ASPSP: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let country: String
    let maximumConsentValidity: Int
    let beta: Bool?
    let bic: String?

    /// No stable id in the EB payload itself — `name`+`country` is unique
    /// enough for list identity (mirrors the old `Institution.id` role).
    var id: String { "\(name)|\(country)" }

    enum CodingKeys: String, CodingKey {
        case name, country, beta, bic
        case maximumConsentValidity = "maximum_consent_validity"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        country = try container.decode(String.self, forKey: .country)
        if let intValue = try? container.decode(Int.self, forKey: .maximumConsentValidity) {
            maximumConsentValidity = intValue
        } else if let doubleValue = try? container.decode(Double.self, forKey: .maximumConsentValidity) {
            maximumConsentValidity = Int(doubleValue)
        } else {
            maximumConsentValidity = 0
        }
        beta = try container.decodeIfPresent(Bool.self, forKey: .beta)
        bic = try container.decodeIfPresent(String.self, forKey: .bic)
    }
}

/// POST /auth response — the URL to open at the ASPSP for consent, plus the
/// identifiers needed to correlate the eventual `/callback`.
struct AuthStartResponse: Codable, Equatable, Sendable {
    let url: String
    let authorizationId: String
    let psuIdHash: String?

    enum CodingKeys: String, CodingKey {
        case url
        case authorizationId = "authorization_id"
        case psuIdHash = "psu_id_hash"
    }
}

/// POST /sessions / GET /sessions/{id} response — the linked accounts plus the
/// consent's access window.
struct SessionResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let accounts: [EBAccount]
    let access: AccessWindow

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case accounts, access
    }

    /// The consent's validity window. `validUntil` is RFC3339 text — kept as a
    /// STRING (never parsed here); a caller that needs a `Date` parses it.
    struct AccessWindow: Codable, Equatable, Sendable {
        let validUntil: String

        enum CodingKeys: String, CodingKey {
            case validUntil = "valid_until"
        }
    }
}

/// One linked account inside a `SessionResponse`. Only `uid` is guaranteed —
/// ASPSPs vary wildly on which of the rest they populate.
struct EBAccount: Codable, Equatable, Sendable, Identifiable {
    let uid: String
    let accountId: String?
    let name: String?
    let currency: String?
    let cashAccountType: String?

    var id: String { uid }

    enum CodingKeys: String, CodingKey {
        case uid, name, currency
        case accountId = "account_id"
        case cashAccountType = "cash_account_type"
    }
}

/// GET /accounts/{uid}/transactions response — one page, plus an opaque cursor
/// (`continuation_key`) for the next page when present.
struct TransactionsPage: Codable, Equatable, Sendable {
    let transactions: [EBTransaction]
    let continuationKey: String?

    enum CodingKeys: String, CodingKey {
        case transactions
        case continuationKey = "continuation_key"
    }
}

/// One bank transaction from Enable Banking. Only the amount block, direction,
/// and status are guaranteed — everything else is optional (bank feeds differ
/// wildly on what they populate).
struct EBTransaction: Codable, Equatable, Sendable {
    let transactionId: String?
    let entryReference: String?
    let transactionAmount: TransactionAmount
    let creditDebitIndicator: String
    let status: String
    let bookingDate: String?
    let valueDate: String?
    let transactionDate: String?
    let debtor: PartyRef?
    let creditor: PartyRef?
    let remittanceInformation: [String]?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case entryReference = "entry_reference"
        case transactionAmount = "transaction_amount"
        case creditDebitIndicator = "credit_debit_indicator"
        case status
        case bookingDate = "booking_date"
        case valueDate = "value_date"
        case transactionDate = "transaction_date"
        case debtor, creditor
        case remittanceInformation = "remittance_information"
    }

    /// The money block. `amount` is a STRING (unsigned in EB's model — sign is
    /// carried separately by `credit_debit_indicator`); parsing to `Decimal` is
    /// Phase 2's job, never `Double`.
    struct TransactionAmount: Codable, Equatable, Sendable {
        let currency: String?
        let amount: String
    }

    /// The counterparty block (`debtor`/`creditor`) — only `name` is relied on.
    struct PartyRef: Codable, Equatable, Sendable {
        let name: String?
    }
}

// MARK: - Client

struct EnableBankingClient: Sendable {

    let session: any HTTPSession
    let secrets: any SecretStoring
    /// Injected clock — kept for parity with the rest of the codebase's
    /// injectable-clock convention (mirrors `RateService`/the old
    /// `GoCardlessClient`) even though nothing here does expiry math today; a
    /// future need (e.g. clamping `startAuth`'s default `validUntil`) then
    /// needs no signature change.
    let now: @Sendable () -> Date

    init(
        session: any HTTPSession = URLSession.shared,
        secrets: any SecretStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.secrets = secrets
        self.now = now
    }

    // MARK: Endpoints

    /// GET /aspsps?country=<code> — the banks available in a country.
    func aspsps(country: String) async throws -> [ASPSP] {
        let request = try jsonRequest("GET", path: "/aspsps", query: ["country": country.uppercased()])
        return try await decode([ASPSP].self, request: request)
    }

    /// POST /auth — start a consent flow at the given ASPSP, returning the URL
    /// to open. `redirectURL` is ALWAYS the worker's own `/callback` — the ONLY
    /// URL registered at the Enable Banking portal (`bani://oauth/callback` is
    /// never sent upstream; the worker's `/callback` is what bounces the user
    /// back into the app via that custom scheme).
    ///
    /// Body shape per Enable Banking's `StartAuthorizationRequest`/`Access`
    /// schema (confirmed against the live API reference, not just the
    /// quick-start sample, which omits the access sub-scopes): `access.balances`
    /// and `access.transactions` are each a plain `Bool` ("Request consent with
    /// balances/transactions access"), NOT a scope-string list — Bani wants
    /// both, so both are always `true`. `psu_type` is `"personal"` (Bani links a
    /// single individual's own accounts, never a business PSU). `language` is
    /// optional per the schema; sent as `"en"` so the ASPSP's consent UI has a
    /// deterministic default regardless of device locale.
    func startAuth(
        aspspName: String,
        country: String,
        validUntil: Date,
        state: UUID = UUID()
    ) async throws -> AuthStartResponse {
        let workerBaseURL = try requireWorkerBaseURL()
        let body: [String: Any] = [
            "access": [
                "balances": true,
                "transactions": true,
                "valid_until": Self.rfc3339Formatter.string(from: validUntil),
            ],
            "aspsp": ["name": aspspName, "country": country],
            "state": state.uuidString,
            "redirect_url": workerBaseURL + "/callback",
            "psu_type": "personal",
            "language": "en",
        ]
        let request = try jsonRequest("POST", path: "/auth", body: body)
        return try await decode(AuthStartResponse.self, request: request)
    }

    /// POST /sessions — exchange the `/callback` authorization `code` for a
    /// session (the linked accounts + access window).
    func createSession(code: String) async throws -> SessionResponse {
        let request = try jsonRequest("POST", path: "/sessions", body: ["code": code])
        return try await decode(SessionResponse.self, request: request)
    }

    /// GET /sessions/{id} — re-fetch a session (accounts + access window).
    func session(id: String) async throws -> SessionResponse {
        let request = try jsonRequest("GET", path: "/sessions/\(id)")
        return try await decode(SessionResponse.self, request: request)
    }

    /// DELETE /sessions/{id} — revoke a session (the Unlink flow).
    func deleteSession(id: String) async throws {
        let request = try jsonRequest("DELETE", path: "/sessions/\(id)")
        _ = try await send(request)
    }

    /// GET /accounts/{uid}/transactions — one page; pass the previous page's
    /// `continuationKey` to walk forward.
    func transactions(
        accountUID: String,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        continuationKey: String? = nil
    ) async throws -> TransactionsPage {
        var query: [String: String] = [:]
        if let dateFrom { query["date_from"] = Self.apiDateFormatter.string(from: dateFrom) }
        if let dateTo { query["date_to"] = Self.apiDateFormatter.string(from: dateTo) }
        if let continuationKey { query["continuation_key"] = continuationKey }
        let request = try jsonRequest("GET", path: "/accounts/\(accountUID)/transactions", query: query)
        return try await decode(TransactionsPage.self, request: request)
    }

    // MARK: Formatting

    /// yyyy-MM-dd in POSIX/UTC — the API's date-only query format. A COMPUTED
    /// property (a fresh instance per access, mirroring the old
    /// `GoCardlessClient.apiDateFormatter` / `DateFieldParser.makeFormatter`) so
    /// there is no shared, non-`Sendable` static state under Swift 6 strict
    /// concurrency.
    static var apiDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// RFC3339 (`access.valid_until` on `POST /auth`) — same COMPUTED-property
    /// reasoning as `apiDateFormatter`.
    static var rfc3339Formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    // MARK: Request building

    /// The configured worker base URL, trailing slash(es) stripped. Throws
    /// `.noCredentials` when unset — the single gate that keeps the whole
    /// feature inert until Settings is filled in.
    private func requireWorkerBaseURL() throws -> String {
        guard var base = secrets.string(for: .workerBaseURL), !base.isEmpty else {
            throw EnableBankingError.noCredentials
        }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw EnableBankingError.noCredentials }
        return base
    }

    private func jsonRequest(
        _ method: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        let base = try requireWorkerBaseURL()
        guard let deviceToken = secrets.string(for: .deviceToken), !deviceToken.isEmpty else {
            throw EnableBankingError.noCredentials
        }
        // Build the absolute URL by string composition — see the historical note
        // in the old GoCardlessClient: `URL.appendingPathComponent` strips/encodes
        // trailing slashes unreliably, so the path is composed verbatim.
        guard var components = URLComponents(string: base + path) else { throw EnableBankingError.transport }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw EnableBankingError.transport }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw EnableBankingError.decoding
        }
    }

    /// Send a request. NO retry-on-401 here — the worker owns upstream auth
    /// entirely; a 401 means the device token itself is wrong and is surfaced
    /// as-is (never retried) for the caller to react to.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            if status == 401 { throw EnableBankingError.unauthorized }
            throw EnableBankingError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as EnableBankingError {
            throw error
        } catch {
            throw EnableBankingError.transport
        }
    }
}
