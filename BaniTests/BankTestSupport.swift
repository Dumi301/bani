import Foundation
import XCTest
@testable import Bani

/// Shared fixtures + the recorded-response network seam for the open-banking
/// suite. CI has NO network to the worker/Enable Banking and NO keys: every
/// client path is exercised against these recorded JSON fixtures through
/// `MockHTTPSession` (injected as the `HTTPSession`), exactly as
/// `RateServiceTests` uses a bundled XML fixture instead of a live BNR call.
enum BankFixtures {

    /// GET /aspsps?country=RO — three ASPSPs proving `maximum_consent_validity`
    /// tolerance (Int on the first row, Double-shaped on the second) and
    /// optional (`beta`/`bic`) presence/absence in every combination.
    static let aspspsRO = """
    [
      {"name":"Raiffeisen Bank","country":"RO","maximum_consent_validity":7776000,"beta":false,"bic":"RZBRROBU"},
      {"name":"Banca Transilvania","country":"RO","maximum_consent_validity":7776000.0},
      {"name":"ING Bank","country":"RO","maximum_consent_validity":15552000,"beta":true}
    ]
    """

    /// POST /auth response — the URL to open at the ASPSP for consent.
    static let authStart = """
    {"url":"https://enablebanking.com/auth/abc123","authorization_id":"auth-abc-123","psu_id_hash":"hash-xyz"}
    """

    /// POST /sessions response — two accounts, the second bare (only `uid`) to
    /// prove `EBAccount`'s missing-optionals tolerance.
    static let sessionCreated = """
    {"session_id":"sess-123","accounts":[
      {"uid":"acc-uid-1","account_id":"acc-1","name":"Cont curent","currency":"RON","cash_account_type":"CACC"},
      {"uid":"acc-uid-2"}
    ],"access":{"valid_until":"2026-11-24T10:00:00.000Z"}}
    """

    /// A mixed page of booked RON transactions:
    ///  - tx-1: CRDT (income) with a debtor name + array remittance.
    ///  - tx-2: DBIT (expense) with a creditor name.
    ///  - tx-3: DBIT, status PEND (a pending row) with a creditor name.
    ///  - a FOURTH row with NO id, NO dates, NO names, NO currency — only the
    ///    required amount block + indicator + status (missing-optionals
    ///    tolerance).
    ///  - tx-5: DBIT, EUR currency (an EUR-account row).
    static let transactionsMixed = """
    {"transactions":[
      {"transaction_id":"tx-1","booking_date":"2026-08-21","transaction_amount":{"currency":"RON","amount":"328.18"},"credit_debit_indicator":"CRDT","status":"BOOK","debtor":{"name":"ACME SRL"},"remittance_information":["Salary","August"]},
      {"transaction_id":"tx-2","booking_date":"2026-08-20","value_date":"2026-08-20","transaction_amount":{"currency":"RON","amount":"15.30"},"credit_debit_indicator":"DBIT","status":"BOOK","creditor":{"name":"Lidl Cluj"},"remittance_information":["Card payment POS"]},
      {"transaction_id":"tx-3","transaction_amount":{"currency":"RON","amount":"42.00"},"credit_debit_indicator":"DBIT","status":"PEND","creditor":{"name":"Uber"}},
      {"transaction_amount":{"amount":"4.50"},"credit_debit_indicator":"DBIT","status":"BOOK"},
      {"transaction_id":"tx-5","transaction_amount":{"currency":"EUR","amount":"9.99"},"credit_debit_indicator":"DBIT","status":"BOOK","creditor":{"name":"Spotify"}}
    ],"continuation_key":null}
    """

    /// Page 1 of a two-page continuation-key walk (a single row + a cursor).
    static let transactionsPage1 = """
    {"transactions":[
      {"transaction_id":"tx-p1","transaction_amount":{"currency":"RON","amount":"10.00"},"credit_debit_indicator":"DBIT","status":"BOOK","creditor":{"name":"Page One Merchant"}}
    ],"continuation_key":"page-2-key"}
    """

    /// Page 2 — no `continuation_key` present at all (tests missing-key ⇒ nil,
    /// not just null ⇒ nil).
    static let transactionsPage2 = """
    {"transactions":[
      {"transaction_id":"tx-p2","transaction_amount":{"currency":"RON","amount":"20.00"},"credit_debit_indicator":"DBIT","status":"BOOK","creditor":{"name":"Page Two Merchant"}}
    ]}
    """

    /// A booked date parsed the same way a mapper would parse it (UTC
    /// midnight), so a planted cross-source duplicate lands on the same
    /// calendar day as a fixture row.
    static func bookingDate(_ yyyyMMdd: String) -> Date {
        EnableBankingClient.apiDateFormatter.date(from: yyyyMMdd) ?? Date()
    }
}

/// A recorded-response `HTTPSession`. Stubs are matched in declaration order by
/// (method, path-substring); a non-`reusable` stub is consumed once (so a
/// two-page continuation-key walk can return page 1 THEN page 2 for the same
/// path), a `reusable` stub answers every matching request (so a second sync
/// pull gets the same data). Thread-safe (`@unchecked Sendable` + `NSLock`) so
/// it satisfies the `Sendable` seam.
final class MockHTTPSession: HTTPSession, @unchecked Sendable {

    struct Stub {
        let method: String
        let pathContains: String
        let status: Int
        let body: Data
        let reusable: Bool
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var consumed: [Bool]
    private var log: [(method: String, path: String, url: String, body: Data?)] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
        self.consumed = Array(repeating: false, count: stubs.count)
    }

    /// Every request seen, as (method, path, url, body) — lets a test assert
    /// e.g. a query parameter (via `url`) or a POST body's shape.
    var requestLog: [(method: String, path: String, url: String, body: Data?)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // Swift 6 forbids `NSLock.lock()/unlock()` directly in an async body, so the
        // lock-guarded resolution lives in a synchronous helper the async func calls.
        respond(to: request)
    }

    /// Synchronous, lock-guarded stub resolution. Behavior is identical to the
    /// former inline body: log the request, return the first unconsumed matching
    /// stub (consuming non-`reusable` ones), else a 404.
    private func respond(to request: URLRequest) -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        log.append((method, path, request.url?.absoluteString ?? "", request.httpBody))
        // Match on the path with any single trailing slash normalized away, so a
        // trailing-slash discrepancy on EITHER side can never cause a false 404.
        func trimSlash(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        let normPath = trimSlash(path)
        for index in stubs.indices where !consumed[index] {
            let stub = stubs[index]
            guard stub.method == method, normPath.contains(trimSlash(stub.pathContains)) else { continue }
            if !stub.reusable { consumed[index] = true }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
            return (stub.body, response)
        }
        // Unmatched → 404 (surfaces as EnableBankingError.http(404, ...), never a crash).
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}

extension MockHTTPSession.Stub {
    static func get(_ path: String, status: Int = 200, json: String, reusable: Bool = false) -> Self {
        .init(method: "GET", pathContains: path, status: status, body: Data(json.utf8), reusable: reusable)
    }
    static func post(_ path: String, status: Int = 200, json: String, reusable: Bool = false) -> Self {
        .init(method: "POST", pathContains: path, status: status, body: Data(json.utf8), reusable: reusable)
    }
    static func delete(_ path: String, status: Int = 200, json: String, reusable: Bool = false) -> Self {
        .init(method: "DELETE", pathContains: path, status: status, body: Data(json.utf8), reusable: reusable)
    }
}

enum BankTestSupport {

    /// An `InMemorySecretStore` carrying a dummy worker base URL + device token
    /// — so `hasCredentials` is true and authorized calls proceed.
    /// `withCachedToken` is VESTIGIAL: the old GoCardless mint/refresh model
    /// cached a `TokenBundle`; the worker model has no such cache (the device
    /// token is sent as-is). The parameter is kept ONLY so call sites in suites
    /// outside this phase's scope (`BankSyncTests`, `BankSyncThrottleTests`,
    /// `BankLinkStoreTests`) keep compiling unchanged.
    static func credentialedSecrets(withCachedToken: Bool = true) -> InMemorySecretStore {
        let secrets = InMemorySecretStore()
        secrets.set("https://bani-proxy.test.workers.dev", for: .workerBaseURL)
        secrets.set("DEVICE_TOKEN_TEST", for: .deviceToken)
        return secrets
    }
}
