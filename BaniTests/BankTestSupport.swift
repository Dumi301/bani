import Foundation
import XCTest
@testable import Bani

/// Shared fixtures + the recorded-response network seam for the P9 open-banking
/// suite. CI has NO network to GoCardless and NO keys: every client path is
/// exercised against these recorded JSON fixtures through `MockHTTPSession`
/// (injected as the `HTTPSession`), exactly as `RateServiceTests` uses a bundled
/// XML fixture instead of a live BNR call.
enum BankFixtures {

    static let tokenNew = """
    {"access":"ACCESS_TOKEN_1","access_expires":86400,"refresh":"REFRESH_TOKEN_1","refresh_expires":2592000}
    """

    static let tokenRefresh = """
    {"access":"ACCESS_TOKEN_2","access_expires":86400}
    """

    static let institutionsRO = """
    [
      {"id":"BANCA_TRANSILVANIA_BTRLRO22","name":"Banca Transilvania","bic":"BTRLRO22","transaction_total_days":"90","countries":["RO"],"logo":"https://cdn.gocardless.com/bt.png"},
      {"id":"ING_INGBROBU","name":"ING Bank","bic":"INGBROBU","transaction_total_days":"730","countries":["RO"]}
    ]
    """

    static let agreement = """
    {"id":"agreement-123","created":"2026-08-24T10:00:00Z","institution_id":"BANCA_TRANSILVANIA_BTRLRO22","max_historical_days":90,"access_valid_for_days":90,"access_scope":["balances","details","transactions"],"accepted":null}
    """

    static let requisitionCreated = """
    {"id":"req-123","created":"2026-08-24T10:00:00Z","redirect":"https://bani.app/oauth/callback","status":"CR","institution_id":"BANCA_TRANSILVANIA_BTRLRO22","agreement":"agreement-123","reference":"ref-1","accounts":[],"link":"https://ob.gocardless.com/psd2/start/req-123/BANCA_TRANSILVANIA_BTRLRO22","ssn":null,"account_selection":false,"redirect_immediate":false}
    """

    static let requisitionLinked = """
    {"id":"req-123","created":"2026-08-24T10:00:00Z","redirect":"https://bani.app/oauth/callback","status":"LN","institution_id":"BANCA_TRANSILVANIA_BTRLRO22","agreement":"agreement-123","reference":"ref-1","accounts":["acc-eur-1","acc-ron-1"],"link":"https://ob.gocardless.com/psd2/start/req-123/BANCA_TRANSILVANIA_BTRLRO22"}
    """

    /// Three booked RON transactions of increasing "variance":
    ///  - tx-1: a fully-populated debit (expense) with a creditor name.
    ///  - tx-2: a credit (income) with a debtor name + array remittance, no valueDate.
    ///  - a THIRD row with NO id, NO dates, NO names — only the required amount block
    ///    (missing-optional-fields tolerance + synthetic bank key + fallbacks).
    static let transactionsRON = """
    {"transactions":{"booked":[
      {"transactionId":"tx-1","bookingDate":"2026-08-20","valueDate":"2026-08-20","transactionAmount":{"amount":"-15.30","currency":"RON"},"creditorName":"Lidl Cluj","remittanceInformationUnstructured":"Card payment POS"},
      {"transactionId":"tx-2","bookingDate":"2026-08-21","transactionAmount":{"amount":"328.18","currency":"RON"},"debtorName":"ACME SRL","remittanceInformationUnstructuredArray":["Salary","August"]},
      {"transactionAmount":{"amount":"-4.50","currency":"RON"}}
    ],"pending":[]}}
    """

    /// A single EUR debit — proves an EUR account decodes + maps to `.eur`.
    static let transactionsEUR = """
    {"transactions":{"booked":[
      {"transactionId":"tx-eur-1","bookingDate":"2026-08-19","transactionAmount":{"amount":"-9.99","currency":"EUR"},"creditorName":"Spotify"}
    ]}}
    """

    /// A booked date parsed the same way the mapper parses it (UTC midnight), so a
    /// planted cross-source duplicate lands on the same calendar day as tx-1.
    static func bookingDate(_ yyyyMMdd: String) -> Date {
        GoCardlessClient.apiDateFormatter.date(from: yyyyMMdd) ?? Date()
    }
}

/// A recorded-response `HTTPSession`. Stubs are matched in declaration order by
/// (method, path-substring); a non-`reusable` stub is consumed once (so the
/// 401→refresh→retry sequence can return 401 THEN 200 for the same path), a
/// `reusable` stub answers every matching request (so a second sync pull gets the
/// same data). Thread-safe (`@unchecked Sendable` + `NSLock`) so it satisfies the
/// `Sendable` seam.
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
    private var log: [(method: String, path: String)] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
        self.consumed = Array(repeating: false, count: stubs.count)
    }

    /// Every request seen, as (method, path) — lets a test assert e.g. that a
    /// `token/refresh` call was actually made on a 401.
    var requestLog: [(method: String, path: String)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        log.append((method, path))
        for index in stubs.indices where !consumed[index] {
            let stub = stubs[index]
            guard stub.method == method, path.contains(stub.pathContains) else { continue }
            if !stub.reusable { consumed[index] = true }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
            return (stub.body, response)
        }
        // Unmatched → 404 (surfaces as GoCardlessError.http(404), never a crash).
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
}

enum BankTestSupport {

    /// An `InMemorySecretStore` carrying dummy secrets — so `hasCredentials` is true
    /// and authorized calls proceed — plus, optionally, a pre-valid cached token so
    /// authorized endpoint tests skip the mint round-trip.
    static func credentialedSecrets(withCachedToken: Bool = true) -> InMemorySecretStore {
        let secrets = InMemorySecretStore()
        secrets.set("SECRET_ID_TEST", for: .secretID)
        secrets.set("SECRET_KEY_TEST", for: .secretKey)
        if withCachedToken {
            let bundle = TokenBundle(
                accessToken: "CACHED_ACCESS",
                accessExpiresAt: Date().addingTimeInterval(3600),
                refreshToken: "CACHED_REFRESH",
                refreshExpiresAt: Date().addingTimeInterval(2_592_000)
            )
            secrets.setValue(bundle, for: .tokenBundle)
        }
        return secrets
    }
}
