import XCTest
@testable import Bani

/// v2.3 — the Bani-worker REST client, exercised ENTIRELY against recorded
/// fixtures through the injectable `HTTPSession` seam (no live network, no
/// keys — the real link is a device-checklist item). Proves: the ASPSP list
/// decoder's `maximum_consent_validity` Int/Double tolerance, the `/auth`
/// request body shape (valid_until + aspsp name/country + the WORKER's own
/// `/callback` as `redirect_url`, never the app's custom scheme), the
/// session/account decoders (incl. a bare account with only `uid`), the
/// transactions decoder (CRDT + DBIT + a PEND row + an EUR row + a row missing
/// almost every optional), a two-page `continuation_key` walk, and that a
/// worker 401 surfaces as `.unauthorized` and is NEVER retried (no JWT dance
/// lives here — that is entirely the worker's job).
final class EnableBankingClientTests: XCTestCase {

    private func client(_ session: MockHTTPSession, secrets: InMemorySecretStore) -> EnableBankingClient {
        EnableBankingClient(session: session, secrets: secrets)
    }

    // MARK: - Credentials gate (no network touched without both secrets)

    func testMissingCredentialsThrowsWithoutTouchingNetwork() async {
        let secrets = InMemorySecretStore() // empty
        let session = MockHTTPSession([])
        do {
            _ = try await client(session, secrets: secrets).aspsps(country: "ro")
            XCTFail("expected noCredentials")
        } catch {
            XCTAssertEqual(error as? EnableBankingError, .noCredentials)
        }
        XCTAssertTrue(session.requestLog.isEmpty, "no credentials ⇒ the network is never touched")
    }

    func testPartialCredentialsThrowsNoCredentials() async {
        let secrets = InMemorySecretStore()
        secrets.set("https://bani-proxy.test.workers.dev", for: .workerBaseURL)
        // deviceToken intentionally left unset.
        let session = MockHTTPSession([])
        do {
            _ = try await client(session, secrets: secrets).aspsps(country: "ro")
            XCTFail("expected noCredentials")
        } catch {
            XCTAssertEqual(error as? EnableBankingError, .noCredentials)
        }
    }

    // MARK: - ASPSPs decode

    func testASPSPsDecodeIncludingIntAndDoubleMaximumConsentValidity() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/aspsps", json: BankFixtures.aspspsRO)])

        let banks = try await client(session, secrets: secrets).aspsps(country: "ro")

        XCTAssertEqual(banks.map(\.name), ["Raiffeisen Bank", "Banca Transilvania", "ING Bank"])
        XCTAssertEqual(banks[0].maximumConsentValidity, 7_776_000, "Int-shaped maximum_consent_validity decodes")
        XCTAssertEqual(banks[1].maximumConsentValidity, 7_776_000, "Double-shaped maximum_consent_validity decodes tolerantly")
        XCTAssertEqual(banks[0].bic, "RZBRROBU")
        XCTAssertNil(banks[1].bic, "a missing optional (bic) never breaks decoding")
        XCTAssertNil(banks[1].beta)
        XCTAssertEqual(banks[2].beta, true)
        XCTAssertTrue(session.requestLog.last?.url.contains("country=RO") == true, "country is sent uppercased")
    }

    // MARK: - startAuth request-body shape

    func testStartAuthSendsValidUntilASPSPNameCountryAndWorkerCallbackRedirect() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/auth", json: BankFixtures.authStart)])
        let validUntil = Date(timeIntervalSince1970: 1_780_000_000)
        let state = UUID()

        let response = try await client(session, secrets: secrets).startAuth(
            aspspName: "Raiffeisen Bank", country: "RO", validUntil: validUntil, state: state
        )

        XCTAssertEqual(response.url, "https://enablebanking.com/auth/abc123")
        XCTAssertEqual(response.authorizationId, "auth-abc-123")
        XCTAssertEqual(response.psuIdHash, "hash-xyz")

        let bodyData = try XCTUnwrap(session.requestLog.last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let access = try XCTUnwrap(json["access"] as? [String: Any])
        XCTAssertNotNil(access["valid_until"], "access.valid_until must be present")
        // Access sub-scopes per the live API reference's `Access` schema —
        // plain booleans, not a scope-string list; Bani always requests both.
        XCTAssertEqual(access["balances"] as? Bool, true)
        XCTAssertEqual(access["transactions"] as? Bool, true)
        let aspsp = try XCTUnwrap(json["aspsp"] as? [String: Any])
        XCTAssertEqual(aspsp["name"] as? String, "Raiffeisen Bank")
        XCTAssertEqual(aspsp["country"] as? String, "RO")
        XCTAssertEqual(json["state"] as? String, state.uuidString)
        // redirect_url is the WORKER's own /callback — the registered redirect —
        // never the app's `bani://oauth/callback` custom scheme.
        XCTAssertEqual(json["redirect_url"] as? String, "https://bani-proxy.test.workers.dev/callback")
        XCTAssertEqual(json["psu_type"] as? String, "personal", "Bani links a single individual, never a business PSU")
        XCTAssertEqual(json["language"] as? String, "en")
    }

    // MARK: - Sessions

    func testCreateSessionDecodesAccountsAndAccessWindow() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/sessions", json: BankFixtures.sessionCreated)])

        let response = try await client(session, secrets: secrets).createSession(code: "auth-code-1")

        XCTAssertEqual(response.sessionId, "sess-123")
        XCTAssertEqual(response.accounts.count, 2)
        XCTAssertEqual(response.accounts.first?.uid, "acc-uid-1")
        XCTAssertEqual(response.accounts.first?.currency, "RON")
        XCTAssertEqual(response.accounts.last?.uid, "acc-uid-2")
        XCTAssertNil(response.accounts.last?.name, "a bare account (only uid) still decodes")
        XCTAssertEqual(response.access.validUntil, "2026-11-24T10:00:00.000Z")

        let bodyData = try XCTUnwrap(session.requestLog.last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "auth-code-1")
    }

    func testSessionByIDDecodes() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/sessions/sess-123", json: BankFixtures.sessionCreated)])

        let response = try await client(session, secrets: secrets).session(id: "sess-123")

        XCTAssertEqual(response.sessionId, "sess-123")
        XCTAssertEqual(response.accounts.count, 2)
    }

    func testDeleteSessionSucceedsOn200() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.delete("/sessions/sess-123", json: "{}")])

        try await client(session, secrets: secrets).deleteSession(id: "sess-123")

        XCTAssertTrue(session.requestLog.contains { $0.method == "DELETE" && $0.path.contains("sessions/sess-123") })
    }

    // MARK: - Transactions decode (CRDT + DBIT + PEND + missing-optionals + EUR)

    func testTransactionsDecodeCRDTDBITPendingAndMissingOptionalRows() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/accounts/acc-uid-1/transactions", json: BankFixtures.transactionsMixed)])

        let page = try await client(session, secrets: secrets).transactions(accountUID: "acc-uid-1")

        XCTAssertEqual(page.transactions.count, 5)
        XCTAssertNil(page.continuationKey, "an explicit JSON null decodes to nil")

        let credit = page.transactions[0]
        XCTAssertEqual(credit.creditDebitIndicator, "CRDT")
        XCTAssertEqual(credit.status, "BOOK")
        XCTAssertEqual(credit.transactionAmount.amount, "328.18")
        XCTAssertEqual(credit.debtor?.name, "ACME SRL")
        XCTAssertEqual(credit.remittanceInformation, ["Salary", "August"])

        let debit = page.transactions[1]
        XCTAssertEqual(debit.creditDebitIndicator, "DBIT")
        XCTAssertEqual(debit.creditor?.name, "Lidl Cluj")

        let pending = page.transactions[2]
        XCTAssertEqual(pending.status, "PEND", "a pending row decodes with its own status, never dropped")
        XCTAssertEqual(pending.creditor?.name, "Uber")

        let bare = page.transactions[3]
        XCTAssertNil(bare.transactionId)
        XCTAssertNil(bare.bookingDate)
        XCTAssertNil(bare.creditor)
        XCTAssertNil(bare.debtor)
        XCTAssertNil(bare.remittanceInformation)
        XCTAssertNil(bare.transactionAmount.currency, "a missing optional currency never breaks decoding")
        XCTAssertEqual(bare.transactionAmount.amount, "4.50")

        let eur = page.transactions[4]
        XCTAssertEqual(eur.transactionAmount.currency, "EUR")
        XCTAssertEqual(eur.transactionAmount.amount, "9.99")
        XCTAssertEqual(eur.creditor?.name, "Spotify")
    }

    func testTransactionsSendsDateRangeAndContinuationKeyAsQueryParams() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/accounts/acc-uid-1/transactions", json: BankFixtures.transactionsPage1)])
        let from = BankFixtures.bookingDate("2026-08-01")
        let to = BankFixtures.bookingDate("2026-08-31")

        _ = try await client(session, secrets: secrets).transactions(
            accountUID: "acc-uid-1", dateFrom: from, dateTo: to, continuationKey: "cursor-1"
        )

        let url = try XCTUnwrap(session.requestLog.last?.url)
        XCTAssertTrue(url.contains("date_from=2026-08-01"))
        XCTAssertTrue(url.contains("date_to=2026-08-31"))
        XCTAssertTrue(url.contains("continuation_key=cursor-1"))
    }

    // MARK: - Two-page continuation_key walk

    func testTwoPageContinuationKeyWalkAtClientLevel() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([
            .get("/accounts/acc-uid-1/transactions", json: BankFixtures.transactionsPage1),
            .get("/accounts/acc-uid-1/transactions", json: BankFixtures.transactionsPage2),
        ])
        let c = client(session, secrets: secrets)

        let page1 = try await c.transactions(accountUID: "acc-uid-1")
        XCTAssertEqual(page1.transactions.map(\.transactionId), ["tx-p1"])
        XCTAssertEqual(page1.continuationKey, "page-2-key")

        let page2 = try await c.transactions(accountUID: "acc-uid-1", continuationKey: page1.continuationKey)
        XCTAssertEqual(page2.transactions.map(\.transactionId), ["tx-p2"])
        XCTAssertNil(page2.continuationKey, "a missing key (not just null) also decodes to nil")

        XCTAssertTrue(session.requestLog.last?.url.contains("continuation_key=page-2-key") == true,
                      "the second page request must carry the first page's cursor")
    }

    // MARK: - Worker 401 → .unauthorized, never retried

    func testWorker401SurfacesAsUnauthorizedNeverRetried() async {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/aspsps", status: 401, json: "{\"error\":\"unauthorized\"}")])
        do {
            _ = try await client(session, secrets: secrets).aspsps(country: "ro")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? EnableBankingError, .unauthorized)
        }
        XCTAssertEqual(session.requestLog.count, 1, "a worker 401 is never retried — that dance is the worker's job upstream")
    }

    // MARK: - Transport / decoding errors are typed (never crashes)

    func testDecodingFailureSurfacesAsDecodingError() async {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/aspsps", json: "not json at all")])
        do {
            _ = try await client(session, secrets: secrets).aspsps(country: "ro")
            XCTFail("expected decoding error")
        } catch {
            XCTAssertEqual(error as? EnableBankingError, .decoding)
        }
    }

    func testHTTPErrorStatusSurfacesTypedWithBody() async {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/aspsps", status: 502, json: "{\"error\":\"bad_gateway\"}")])
        do {
            _ = try await client(session, secrets: secrets).aspsps(country: "ro")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? EnableBankingError, .http(status: 502, body: "{\"error\":\"bad_gateway\"}"))
        }
    }
}
