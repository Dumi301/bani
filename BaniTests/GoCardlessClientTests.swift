import XCTest
@testable import Bani

/// P9 — the GoCardless REST client, exercised ENTIRELY against recorded fixtures
/// through the injectable `HTTPSession` seam (no live network, no keys — the real
/// link is a device-checklist item). Proves: token mint, refresh-on-401, the
/// institutions/requisition/transactions decoders, amount-string→`Decimal`, an EUR
/// account, and tolerance of a transaction that omits almost every optional field.
final class GoCardlessClientTests: XCTestCase {

    private func client(_ session: MockHTTPSession, secrets: InMemorySecretStore) -> GoCardlessClient {
        GoCardlessClient(baseURL: URL(string: "https://example.test")!, session: session, secrets: secrets)
    }

    // MARK: - Token mint

    func testMintTokenExchangesSecretsForTokenPair() async throws {
        let secrets = InMemorySecretStore()
        secrets.set("SID", for: .secretID)
        secrets.set("SKEY", for: .secretKey)
        let session = MockHTTPSession([.post("/api/v2/token/new/", json: BankFixtures.tokenNew)])

        let token = try await client(session, secrets: secrets).mintToken()

        XCTAssertEqual(token.access, "ACCESS_TOKEN_1")
        XCTAssertEqual(token.accessExpires, 86_400)
        XCTAssertEqual(token.refresh, "REFRESH_TOKEN_1")
    }

    func testValidAccessTokenThrowsWithoutCredentials() async {
        let secrets = InMemorySecretStore() // empty
        let session = MockHTTPSession([])
        do {
            _ = try await client(session, secrets: secrets).validAccessToken()
            XCTFail("expected noCredentials")
        } catch {
            XCTAssertEqual(error as? GoCardlessError, .noCredentials)
        }
    }

    func testMintPersistsBundleSoSecondCallReusesCachedToken() async throws {
        let secrets = InMemorySecretStore()
        secrets.set("SID", for: .secretID)
        secrets.set("SKEY", for: .secretKey)
        // Only ONE token/new stub: the second token request would 404. If the client
        // re-minted instead of reusing the cache, the second call would fail.
        let session = MockHTTPSession([.post("/api/v2/token/new/", json: BankFixtures.tokenNew)])
        let c = client(session, secrets: secrets)

        let first = try await c.validAccessToken()
        let second = try await c.validAccessToken()

        XCTAssertEqual(first, "ACCESS_TOKEN_1")
        XCTAssertEqual(second, "ACCESS_TOKEN_1")
        XCTAssertEqual(session.requestLog.filter { $0.path.contains("token/new") }.count, 1,
                       "the cached token must be reused, not re-minted")
    }

    // MARK: - Refresh on 401

    func testAuthorizedRequestRefreshesAndRetriesOn401() async throws {
        let secrets = BankTestSupport.credentialedSecrets(withCachedToken: true)
        // First institutions call → 401; the client must refresh the token, then the
        // retry → 200 with the real body.
        let session = MockHTTPSession([
            .get("/api/v2/institutions/", status: 401, json: "{}"),
            .post("/api/v2/token/refresh/", json: BankFixtures.tokenRefresh),
            .get("/api/v2/institutions/", status: 200, json: BankFixtures.institutionsRO),
        ])

        let institutions = try await client(session, secrets: secrets).institutions(country: "ro")

        XCTAssertEqual(institutions.count, 2)
        XCTAssertEqual(institutions.first?.name, "Banca Transilvania")
        XCTAssertTrue(session.requestLog.contains { $0.path.contains("token/refresh") },
                      "a 401 must trigger a token refresh")
    }

    func testUnauthorizedAfterRetrySurfacesAsUnauthorized() async {
        let secrets = BankTestSupport.credentialedSecrets(withCachedToken: true)
        // Both the initial call and the post-refresh retry return 401.
        let session = MockHTTPSession([
            .get("/api/v2/institutions/", status: 401, json: "{}"),
            .post("/api/v2/token/refresh/", json: BankFixtures.tokenRefresh),
            .get("/api/v2/institutions/", status: 401, json: "{}"),
        ])
        do {
            _ = try await client(session, secrets: secrets).institutions(country: "ro")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? GoCardlessError, .unauthorized)
        }
    }

    // MARK: - Institutions decode

    func testInstitutionsDecodeIncludingStringTransactionDays() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/api/v2/institutions/", json: BankFixtures.institutionsRO)])

        let institutions = try await client(session, secrets: secrets).institutions(country: "ro")

        XCTAssertEqual(institutions.map(\.id), ["BANCA_TRANSILVANIA_BTRLRO22", "ING_INGBROBU"])
        // `transaction_total_days` is a STRING in the API — defensively typed.
        XCTAssertEqual(institutions.first?.transactionTotalDays, "90")
        XCTAssertNil(institutions.last?.logo, "a missing optional (logo) never breaks decoding")
    }

    // MARK: - Requisition create / poll

    func testCreateRequisitionReturnsCreatedStateWithLink() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/api/v2/requisitions/", json: BankFixtures.requisitionCreated)])

        let req = try await client(session, secrets: secrets).createRequisition(
            institutionID: "BANCA_TRANSILVANIA_BTRLRO22", agreementID: "agreement-123",
            reference: "ref-1", redirect: "https://bani.app/oauth/callback"
        )

        XCTAssertEqual(req.status, "CR")
        XCTAssertEqual(req.accounts, [])
        XCTAssertEqual(req.link, "https://ob.gocardless.com/psd2/start/req-123/BANCA_TRANSILVANIA_BTRLRO22")
    }

    func testPollRequisitionReturnsLinkedStateWithAccounts() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/api/v2/requisitions/req-123/", json: BankFixtures.requisitionLinked)])

        let req = try await client(session, secrets: secrets).requisition(id: "req-123")

        XCTAssertEqual(req.status, "LN")
        XCTAssertEqual(req.accounts, ["acc-eur-1", "acc-ron-1"])
    }

    func testCreateAgreementDecodes() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/api/v2/agreements/enduser/", json: BankFixtures.agreement)])

        let agreement = try await client(session, secrets: secrets).createAgreement(institutionID: "BANCA_TRANSILVANIA_BTRLRO22")

        XCTAssertEqual(agreement.id, "agreement-123")
        XCTAssertEqual(agreement.accessValidForDays, 90)
    }

    // MARK: - Transactions decode + amount → Decimal

    func testTransactionsDecodeAmountsAsDecimalNeverDouble() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/accounts/acc-ron-1/transactions/", json: BankFixtures.transactionsRON)])

        let response = try await client(session, secrets: secrets).transactions(accountID: "acc-ron-1")
        let booked = try XCTUnwrap(response.transactions.booked)
        XCTAssertEqual(booked.count, 3)

        // The amount is the raw signed STRING — never parsed through Double.
        XCTAssertEqual(booked[0].transactionAmount.amount, "-15.30")
        let parsed = try XCTUnwrap(BankSyncMapper.parseAmount(booked[0].transactionAmount.amount))
        XCTAssertEqual(parsed.magnitude, Decimal(string: "15.30"))
        XCTAssertEqual(parsed.direction, .expense)

        // A string that would lose precision as a Double (0.1-family) stays exact.
        let credit = try XCTUnwrap(BankSyncMapper.parseAmount(booked[1].transactionAmount.amount))
        XCTAssertEqual(credit.magnitude, Decimal(string: "328.18"))
        XCTAssertEqual(credit.direction, .income)
    }

    func testEURAccountDecodesAndMapsToEUR() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/accounts/acc-eur-1/transactions/", json: BankFixtures.transactionsEUR)])

        let response = try await client(session, secrets: secrets).transactions(accountID: "acc-eur-1")
        let booked = try XCTUnwrap(response.transactions.booked)
        let draft = try XCTUnwrap(BankSyncMapper.draft(from: booked[0], accountCurrency: .eur))

        XCTAssertEqual(draft.currency, .eur)
        XCTAssertEqual(draft.amount, Decimal(string: "9.99"))
        XCTAssertEqual(draft.direction, .expense)
        XCTAssertEqual(draft.counterparty, "Spotify")
    }

    func testTransactionMissingOptionalFieldsStillDecodesAndMaps() async throws {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/accounts/acc-ron-1/transactions/", json: BankFixtures.transactionsRON)])

        let response = try await client(session, secrets: secrets).transactions(accountID: "acc-ron-1")
        let bare = try XCTUnwrap(response.transactions.booked?.last)

        // The bare row has no id, no dates, no names — only the amount block.
        XCTAssertNil(bare.transactionId)
        XCTAssertNil(bare.bookingDate)
        XCTAssertNil(bare.creditorName)

        let draft = try XCTUnwrap(BankSyncMapper.draft(from: bare, accountCurrency: .ron),
                                  "a bare transaction must still map, never crash")
        XCTAssertEqual(draft.amount, Decimal(string: "4.50"))
        XCTAssertEqual(draft.direction, .expense)
        // No counterparty/remittance → the localized fallback description.
        XCTAssertEqual(draft.descriptionText, String(localized: "bank.tx.fallback"))
        // No id → a synthetic, stable bank key (so a re-pull still dedupes).
        XCTAssertTrue(draft.bankKey.hasPrefix("syn:"))
    }

    // MARK: - Transport / decoding errors are typed (never crashes)

    func testDecodingFailureSurfacesAsDecodingError() async {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/api/v2/institutions/", json: "not json at all")])
        do {
            _ = try await client(session, secrets: secrets).institutions(country: "ro")
            XCTFail("expected decoding error")
        } catch {
            XCTAssertEqual(error as? GoCardlessError, .decoding)
        }
    }

    func testHTTPErrorStatusSurfacesTyped() async {
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/api/v2/institutions/", status: 500, json: "{}")])
        do {
            _ = try await client(session, secrets: secrets).institutions(country: "ro")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? GoCardlessError, .http(status: 500))
        }
    }
}
