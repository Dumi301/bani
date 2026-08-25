import Foundation

/// P9 — the pure REST client for GoCardless Bank Account Data (ex-Nordigen). NO
/// SDK, NO backend: raw `URLRequest`/`URLSession` against the documented v2 API,
/// exactly mirroring `RateService`'s conventions — one injectable network seam
/// (`HTTPSession`, defaulting to `URLSession.shared`) so every path is exercised
/// on CI against recorded fixtures with NO live network and NO keys, and every
/// failure is a thrown `GoCardlessError` the caller can silently absorb (the
/// RateService "network failure is silent" rule).
///
/// The client is a `Sendable` value: it owns no mutable state. The bearer token is
/// cached in the Keychain via `SecretStoring`, so concurrent calls stay correct and
/// nothing secret is ever held in memory longer than a request.
///
/// Decoding is TOLERANT throughout: bank feeds vary enormously between institutions,
/// so every response field the app does not strictly require is optional and a
/// missing/extra field never throws (proven by the missing-optional-fields test).
/// Amounts arrive as STRINGS and are parsed to `Decimal` — never `Double`.

// MARK: - Network seam

/// The one-method network seam (mirrors `URLSession.data(for:)`). Injectable so
/// tests feed recorded fixtures; production uses `URLSession.shared`.
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

// MARK: - Errors

/// Every failure mode, tolerant by design — the caller (BankSyncService / the
/// Settings view) turns any of these into a silent retry/backoff, never a crash
/// and never a blocking alert.
enum GoCardlessError: Error, Equatable {
    /// No `secret_id`/`secret_key` entered yet — the feature is inert.
    case noCredentials
    /// A non-2xx HTTP status (carries the code for logging-free branching).
    case http(status: Int)
    /// The bearer token was rejected even after a refresh attempt.
    case unauthorized
    /// The body could not be decoded into the expected shape.
    case decoding
    /// A transport-level failure (offline, DNS, timeout, …).
    case transport
}

// MARK: - Token bundle

/// The cached bearer credentials. `access` is short-lived (~24h); `refresh` mints a
/// new access token WITHOUT re-sending the user's secrets (~30 days). When the
/// refresh token itself expires the client re-mints from the Keychain secrets.
struct TokenBundle: Codable, Equatable, Sendable {
    var accessToken: String
    var accessExpiresAt: Date
    var refreshToken: String?
    var refreshExpiresAt: Date?

    func isAccessValid(now: Date = .now, skew: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(skew) < accessExpiresAt
    }

    func isRefreshValid(now: Date = .now, skew: TimeInterval = 60) -> Bool {
        guard refreshToken != nil, let refreshExpiresAt else { return false }
        return now.addingTimeInterval(skew) < refreshExpiresAt
    }
}

// MARK: - DTOs (tolerant, optional-heavy)

/// POST /token/new/ and /token/refresh/ responses. `/refresh/` omits the refresh
/// fields, so they are optional.
struct TokenResponse: Codable, Equatable, Sendable {
    let access: String
    let accessExpires: Int?
    let refresh: String?
    let refreshExpires: Int?

    enum CodingKeys: String, CodingKey {
        case access
        case accessExpires = "access_expires"
        case refresh
        case refreshExpires = "refresh_expires"
    }

    /// Build a `TokenBundle` anchored at `now` (expiries are relative seconds).
    func bundle(now: Date = .now) -> TokenBundle {
        TokenBundle(
            accessToken: access,
            accessExpiresAt: now.addingTimeInterval(TimeInterval(accessExpires ?? 86_400)),
            refreshToken: refresh,
            refreshExpiresAt: refresh.map { _ in now.addingTimeInterval(TimeInterval(refreshExpires ?? 2_592_000)) }
        )
    }
}

/// GET /institutions/?country=ro element. Only `id`/`name` are relied on;
/// `transaction_total_days` is a STRING in the API (defensive typing).
struct Institution: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let bic: String?
    let transactionTotalDays: String?
    let logo: String?

    enum CodingKeys: String, CodingKey {
        case id, name, bic, logo
        case transactionTotalDays = "transaction_total_days"
    }
}

/// POST /agreements/enduser/ response — the end-user agreement (access window).
struct AgreementResponse: Codable, Equatable, Sendable {
    let id: String
    let institutionId: String?
    let maxHistoricalDays: Int?
    let accessValidForDays: Int?
    let created: String?

    enum CodingKeys: String, CodingKey {
        case id, created
        case institutionId = "institution_id"
        case maxHistoricalDays = "max_historical_days"
        case accessValidForDays = "access_valid_for_days"
    }
}

/// POST/GET /requisitions/ response — the bank-link handle. `link` is the URL the
/// user opens to authenticate; `accounts` fills once `status == "LN"`.
struct RequisitionResponse: Codable, Equatable, Sendable {
    let id: String
    let status: String?
    let link: String?
    let accounts: [String]?
    let institutionId: String?
    let agreement: String?
    let reference: String?
    let created: String?

    enum CodingKeys: String, CodingKey {
        case id, status, link, accounts, agreement, reference, created
        case institutionId = "institution_id"
    }
}

/// GET /accounts/{id}/transactions/ response. Some banks omit `pending`.
struct AccountTransactionsResponse: Codable, Equatable, Sendable {
    let transactions: TransactionBuckets

    struct TransactionBuckets: Codable, Equatable, Sendable {
        let booked: [BankTransaction]?
        let pending: [BankTransaction]?
    }
}

/// One bank transaction. Almost everything is optional — bank feeds differ wildly.
/// `transactionAmount` is the only required field; its `.amount` is a signed STRING.
struct BankTransaction: Codable, Equatable, Sendable {
    let transactionId: String?
    let internalTransactionId: String?
    let bookingDate: String?
    let valueDate: String?
    let bookingDateTime: String?
    let transactionAmount: BankAmount
    let creditorName: String?
    let debtorName: String?
    let remittanceInformationUnstructured: String?
    let remittanceInformationUnstructuredArray: [String]?
    let additionalInformation: String?

    enum CodingKeys: String, CodingKey {
        case transactionId, internalTransactionId, bookingDate, valueDate, bookingDateTime
        case transactionAmount, creditorName, debtorName
        case remittanceInformationUnstructured, remittanceInformationUnstructuredArray
        case additionalInformation
    }
}

/// The signed-string money field. `Decimal`, never `Double`.
struct BankAmount: Codable, Equatable, Sendable {
    let amount: String
    let currency: String
}

// MARK: - Client

struct GoCardlessClient: Sendable {

    /// The current GoCardless Bank Account Data host. RISK: verify on device — the
    /// host + `/api/v2` prefix are the ex-Nordigen scheme and may change.
    static let defaultBaseURL = URL(string: "https://bankaccountdata.gocardless.com")!

    let baseURL: URL
    let session: any HTTPSession
    let secrets: any SecretStoring
    /// Injected clock so token-expiry logic is deterministic in tests.
    let now: @Sendable () -> Date

    init(
        baseURL: URL = GoCardlessClient.defaultBaseURL,
        session: any HTTPSession = URLSession.shared,
        secrets: any SecretStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.secrets = secrets
        self.now = now
    }

    // MARK: Token lifecycle

    /// A valid bearer token, minting or refreshing as needed. The cached bundle is
    /// reused while its access token is fresh; an expired access token is refreshed
    /// (no secrets re-sent) if the refresh token is still valid, else re-minted.
    func validAccessToken() async throws -> String {
        guard secrets.hasCredentials else { throw GoCardlessError.noCredentials }
        if let bundle: TokenBundle = secrets.value(TokenBundle.self, for: .tokenBundle), bundle.isAccessValid(now: now()) {
            return bundle.accessToken
        }
        return try await renewToken().accessToken
    }

    /// Force a token renewal: refresh when possible, else mint. Persists the new
    /// bundle. Used both proactively (expiry) and reactively (a 401).
    @discardableResult
    func renewToken() async throws -> TokenBundle {
        guard secrets.hasCredentials else { throw GoCardlessError.noCredentials }
        if let existing: TokenBundle = secrets.value(TokenBundle.self, for: .tokenBundle),
           existing.isRefreshValid(now: now()), let refresh = existing.refreshToken {
            if let refreshed = try? await refreshAccess(refresh: refresh) {
                let merged = TokenBundle(
                    accessToken: refreshed.access,
                    accessExpiresAt: now().addingTimeInterval(TimeInterval(refreshed.accessExpires ?? 86_400)),
                    refreshToken: existing.refreshToken,
                    refreshExpiresAt: existing.refreshExpiresAt
                )
                secrets.setValue(merged, for: .tokenBundle)
                return merged
            }
        }
        let minted = try await mintToken().bundle(now: now())
        secrets.setValue(minted, for: .tokenBundle)
        return minted
    }

    /// POST /api/v2/token/new/ — exchange the user's secrets for a token pair.
    func mintToken() async throws -> TokenResponse {
        guard let id = secrets.string(for: .secretID), let key = secrets.string(for: .secretKey),
              !id.isEmpty, !key.isEmpty else { throw GoCardlessError.noCredentials }
        let request = try jsonRequest(
            "POST", path: "/api/v2/token/new/",
            body: ["secret_id": id, "secret_key": key], authorized: false
        )
        return try await decode(TokenResponse.self, request: request, retryOn401: false)
    }

    /// POST /api/v2/token/refresh/ — mint a fresh access token from a refresh token.
    func refreshAccess(refresh: String) async throws -> TokenResponse {
        let request = try jsonRequest(
            "POST", path: "/api/v2/token/refresh/",
            body: ["refresh": refresh], authorized: false
        )
        return try await decode(TokenResponse.self, request: request, retryOn401: false)
    }

    // MARK: Endpoints

    /// GET /api/v2/institutions/?country=<code> — the banks available in a country.
    func institutions(country: String) async throws -> [Institution] {
        let request = try jsonRequest("GET", path: "/api/v2/institutions/", query: ["country": country.lowercased()])
        return try await decode([Institution].self, request: request)
    }

    /// POST /api/v2/agreements/enduser/ — create the end-user access agreement.
    func createAgreement(institutionID: String, maxHistoricalDays: Int = 90, accessValidForDays: Int = 90) async throws -> AgreementResponse {
        let request = try jsonRequest("POST", path: "/api/v2/agreements/enduser/", body: [
            "institution_id": institutionID,
            "max_historical_days": maxHistoricalDays,
            "access_valid_for_days": accessValidForDays,
            "access_scope": ["balances", "details", "transactions"],
        ])
        return try await decode(AgreementResponse.self, request: request)
    }

    /// POST /api/v2/requisitions/ — create the requisition, returning the `link` URL
    /// the user opens to authenticate at their bank.
    func createRequisition(institutionID: String, agreementID: String, reference: String, redirect: String) async throws -> RequisitionResponse {
        let request = try jsonRequest("POST", path: "/api/v2/requisitions/", body: [
            "institution_id": institutionID,
            "agreement": agreementID,
            "reference": reference,
            "redirect": redirect,
            "user_language": "EN",
        ])
        return try await decode(RequisitionResponse.self, request: request)
    }

    /// GET /api/v2/requisitions/{id}/ — poll the requisition for `status`/`accounts`.
    func requisition(id: String) async throws -> RequisitionResponse {
        let request = try jsonRequest("GET", path: "/api/v2/requisitions/\(id)/")
        return try await decode(RequisitionResponse.self, request: request)
    }

    /// GET /api/v2/accounts/{id}/transactions/ — booked+pending, optionally from a date.
    func transactions(accountID: String, dateFrom: Date? = nil) async throws -> AccountTransactionsResponse {
        var query: [String: String] = [:]
        if let dateFrom { query["date_from"] = Self.apiDateFormatter.string(from: dateFrom) }
        let request = try jsonRequest("GET", path: "/api/v2/accounts/\(accountID)/transactions/", query: query)
        return try await decode(AccountTransactionsResponse.self, request: request)
    }

    // MARK: Request building

    /// yyyy-MM-dd in POSIX/UTC — the API's date format, locale-independent. A
    /// COMPUTED property (a fresh instance per access, mirroring
    /// `DateFieldParser.makeFormatter`) so there is no shared, non-`Sendable` static
    /// state under Swift 6 strict concurrency.
    static var apiDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private func jsonRequest(
        _ method: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        authorized: Bool = true
    ) throws -> URLRequest {
        // Build the absolute URL by string composition. `URL.appendingPathComponent`
        // strips/encodes the trailing slash, and setting `URLComponents.path` after
        // the fact does not reliably restore it in the final `.url` — so the exact
        // path, INCLUDING the trailing slash GoCardless requires (`/api/v2/.../`), is
        // composed verbatim from the base host and used directly.
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + path) else { throw GoCardlessError.transport }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GoCardlessError.transport }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        // The bearer header is stamped at send time (so a 401-retry can restamp a
        // freshly-renewed token); mark whether this request needs auth.
        request.setValue(authorized ? "1" : "0", forHTTPHeaderField: Self.authMarkerHeader)
        return request
    }

    /// Internal marker header (stripped before sending) telling `send` whether to
    /// attach + refresh a bearer token.
    private static let authMarkerHeader = "X-Bani-Authorized"

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest, retryOn401: Bool = true) async throws -> T {
        let data = try await send(request, retryOn401: retryOn401)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoCardlessError.decoding
        }
    }

    /// Send a request, attaching a bearer token when marked authorized, and — for
    /// authorized requests — transparently renewing the token and retrying ONCE on a
    /// 401 (the refresh-on-401 contract).
    private func send(_ request: URLRequest, retryOn401: Bool) async throws -> Data {
        let authorized = request.value(forHTTPHeaderField: Self.authMarkerHeader) != "0"
        var attempt = request
        attempt.setValue(nil, forHTTPHeaderField: Self.authMarkerHeader)
        if authorized {
            let token = try await validAccessToken()
            attempt.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await perform(attempt)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200

        if status == 401, authorized, retryOn401 {
            // Token rejected — renew (refresh, else mint) and retry exactly once.
            let renewed = try await renewToken()
            var retry = request
            retry.setValue(nil, forHTTPHeaderField: Self.authMarkerHeader)
            retry.setValue("Bearer \(renewed.accessToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await perform(retry)
            let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(retryStatus) else {
                throw retryStatus == 401 ? GoCardlessError.unauthorized : GoCardlessError.http(status: retryStatus)
            }
            return retryData
        }

        guard (200..<300).contains(status) else {
            throw status == 401 ? GoCardlessError.unauthorized : GoCardlessError.http(status: status)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as GoCardlessError {
            throw error
        } catch {
            throw GoCardlessError.transport
        }
    }
}
