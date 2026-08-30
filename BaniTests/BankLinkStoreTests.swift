import XCTest
import SwiftData
@testable import Bani

/// v2.3 — the link lifecycle state machine (`BankLinkState.derive`) and the
/// consent-expiry-warning function. Pure and source-free, so every transition is
/// asserted without network or the Keychain. Also proves the additive `BankLink`
/// `@Model` registers migration-safely in the production schema (an in-memory
/// `BaniModelContainer` carrying the FULL schema) and exercises `beginLink`/
/// `completeLink`/`unlink` against `MockHTTPSession`.
final class BankLinkStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000) // fixed clock

    private func snap(
        authorizationID: String? = nil, sessionID: String? = nil,
        accounts: [String] = [], consentValidUntil: Date? = nil, sessionRevoked: Bool = false
    ) -> BankLinkSnapshot {
        BankLinkSnapshot(
            authorizationID: authorizationID, sessionID: sessionID, accountIDs: accounts,
            consentValidUntil: consentValidUntil, sessionRevoked: sessionRevoked
        )
    }

    // MARK: - Transitions

    func testNoneWhenNothingStarted() {
        XCTAssertEqual(BankLinkState.derive(from: snap(), now: now), .none)
    }

    func testLinkPendingAfterAuthStartedButNoSessionYet() {
        let state = BankLinkState.derive(from: snap(authorizationID: "auth-1"), now: now)
        XCTAssertEqual(state, .linkPending)
    }

    func testLinkedWhenSessionHasAccountsAndConsentStillValid() {
        let state = BankLinkState.derive(
            from: snap(authorizationID: "auth-1", sessionID: "sess-1", accounts: ["acc-1", "acc-2"], consentValidUntil: now.addingTimeInterval(86_400)),
            now: now
        )
        XCTAssertEqual(state, .linked(accountIDs: ["acc-1", "acc-2"]))
        XCTAssertTrue(state.isLinked)
        XCTAssertEqual(state.accountIDs, ["acc-1", "acc-2"])
    }

    func testSessionWithNoAccountsFallsBackToLinkPending() {
        let state = BankLinkState.derive(
            from: snap(authorizationID: "auth-1", sessionID: "sess-1", accounts: [], consentValidUntil: now.addingTimeInterval(86_400)),
            now: now
        )
        XCTAssertEqual(state, .linkPending)
    }

    // MARK: - Expiry → re-link (both causes)

    func testExpiredWhenConsentWindowPassedEvenIfSessionStillHasAccounts() {
        // A stale-but-present session must NOT mask an expired consent window.
        let state = BankLinkState.derive(
            from: snap(authorizationID: "auth-1", sessionID: "sess-1", accounts: ["acc-1"], consentValidUntil: now.addingTimeInterval(-1)),
            now: now
        )
        XCTAssertEqual(state, .expired)
        XCTAssertTrue(state.needsRelink)
    }

    func testExpiredWhenSessionRevokedEvenIfConsentWindowStillOpen() {
        let state = BankLinkState.derive(
            from: snap(authorizationID: "auth-1", sessionID: "sess-1", accounts: ["acc-1"], consentValidUntil: now.addingTimeInterval(86_400), sessionRevoked: true),
            now: now
        )
        XCTAssertEqual(state, .expired)
        XCTAssertTrue(state.needsRelink)
    }

    func testExpiredWhenRevokedDuringAnInFlightAuthorizationTooNoSessionYet() {
        // Defensive: revocation can in principle be flagged even before a
        // session ever completed (e.g. a stale in-flight authorization).
        let state = BankLinkState.derive(from: snap(authorizationID: "auth-1", sessionRevoked: true), now: now)
        XCTAssertEqual(state, .expired)
    }

    // MARK: - Consent-expiry warning (pure, next to derive)

    func testConsentExpiryWarningNilWhenNoConsentValidUntil() {
        XCTAssertNil(BankLinkState.consentExpiryWarningDays(consentValidUntil: nil, now: now))
    }

    func testConsentExpiryWarningNilWhenAlreadyExpired() {
        XCTAssertNil(BankLinkState.consentExpiryWarningDays(consentValidUntil: now.addingTimeInterval(-1), now: now))
    }

    func testConsentExpiryWarningNilWhenFarFromExpiry() {
        XCTAssertNil(BankLinkState.consentExpiryWarningDays(consentValidUntil: now.addingTimeInterval(10 * 86_400), now: now))
    }

    func testConsentExpiryWarningReturnsDaysRemainingWithinWindow() {
        XCTAssertEqual(BankLinkState.consentExpiryWarningDays(consentValidUntil: now.addingTimeInterval(3 * 86_400), now: now), 3)
    }

    func testConsentExpiryWarningAtSevenDayBoundaryIsIncluded() {
        XCTAssertEqual(BankLinkState.consentExpiryWarningDays(consentValidUntil: now.addingTimeInterval(7 * 86_400), now: now), 7)
    }

    func testConsentExpiryWarningJustOverSevenDaysIsExcluded() {
        XCTAssertNil(BankLinkState.consentExpiryWarningDays(consentValidUntil: now.addingTimeInterval(7 * 86_400 + 3_600), now: now))
    }

    func testConsentExpiryWarningRoundsPartialDayUp() {
        // 6 days + 1 hour remaining → still "7 days" (rounds up, never a
        // misleadingly reassuring floor).
        XCTAssertEqual(BankLinkState.consentExpiryWarningDays(consentValidUntil: now.addingTimeInterval(6 * 86_400 + 3_600), now: now), 7)
    }

    // MARK: - Persisted model round-trip (proves additive schema registration)

    @MainActor
    func testBankLinkModelPersistsAndDerivesLinkedState() throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let link = BankLink(
            accountIDs: ["acc-eur-1", "acc-ron-1"],
            sessionID: "sess-123",
            authorizationID: "auth-123",
            aspspName: "Banca Transilvania",
            aspspCountry: "RO",
            consentValidUntil: now.addingTimeInterval(90 * 86_400)
        )
        context.insert(link)
        try context.save()

        let fetched = try XCTUnwrap((try? context.fetch(FetchDescriptor<BankLink>()))?.first)
        XCTAssertEqual(fetched.accountIDs, ["acc-eur-1", "acc-ron-1"])
        XCTAssertEqual(BankLinkState.derive(from: fetched.snapshot, now: now), .linked(accountIDs: ["acc-eur-1", "acc-ron-1"]))
    }

    /// A pre-v2.3 (GoCardless-shaped) row — only the OLD columns set, every new
    /// v2.3 column left at its default — must still decode fine against the
    /// FULL v2.3 schema (additive-optional law), and the NEW derive function
    /// correctly reports `.none` for it (no `authorizationID`/`sessionID` ⇒
    /// nothing v2.3 recognizes as started — the old GoCardless link is
    /// meaningless under Enable Banking and the user is expected to re-link).
    @MainActor
    func testPreV23ShapedRowDecodesWithNewColumnsNilAndDerivesNone() throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let legacy = BankLink(
            institutionID: "BANCA_TRANSILVANIA_BTRLRO22",
            institutionName: "Banca Transilvania",
            agreementID: "agreement-123",
            requisitionID: "req-123",
            statusCode: "LN",
            accountIDs: ["acc-eur-1", "acc-ron-1"],
            agreementExpiresAt: now.addingTimeInterval(90 * 86_400)
        )
        context.insert(legacy)
        try context.save()

        let fetched = try XCTUnwrap((try? context.fetch(FetchDescriptor<BankLink>()))?.first)
        XCTAssertEqual(fetched.institutionName, "Banca Transilvania", "old columns round-trip unchanged")
        XCTAssertNil(fetched.sessionID, "every new v2.3 column decodes nil for a pre-v2.3 row")
        XCTAssertNil(fetched.authorizationID)
        XCTAssertNil(fetched.aspspName)
        XCTAssertNil(fetched.aspspCountry)
        XCTAssertNil(fetched.consentValidUntil)
        XCTAssertNil(fetched.sessionRevoked)
        XCTAssertEqual(BankLinkState.derive(from: fetched.snapshot, now: now), .none)
    }

    // MARK: - beginLink / completeLink (against MockHTTPSession)

    @MainActor
    func testBeginLinkPersistsAuthorizationURLAndASPSP() async throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/auth", json: BankFixtures.authStart)])
        let client = EnableBankingClient(session: session, secrets: secrets)
        let store = BankLinkStore(context: context, client: client)
        let aspsp = try JSONDecoder().decode(
            ASPSP.self,
            from: Data(#"{"name":"Raiffeisen Bank","country":"RO","maximum_consent_validity":7776000}"#.utf8)
        )

        let url = await store.beginLink(aspsp: aspsp)

        XCTAssertEqual(url?.absoluteString, "https://enablebanking.com/auth/abc123")
        XCTAssertEqual(store.state, .linkPending)
        XCTAssertEqual(store.link?.authorizationID, "auth-abc-123")
        XCTAssertEqual(store.link?.aspspName, "Raiffeisen Bank")
        XCTAssertEqual(store.link?.aspspCountry, "RO")
        XCTAssertEqual(store.link?.linkURL, "https://enablebanking.com/auth/abc123")
        XCTAssertNotNil(store.link?.requisitionID, "the /auth state UUID is persisted for the callback correlation check")
    }

    @MainActor
    func testCompleteLinkPersistsSessionAccountsAndConsentValidUntilAndReachesLinked() async throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/sessions", json: BankFixtures.sessionCreated)])
        let client = EnableBankingClient(session: session, secrets: secrets)
        let store = BankLinkStore(context: context, client: client)

        let state = await store.completeLink(code: "auth-code-1")

        XCTAssertEqual(state, .linked(accountIDs: ["acc-uid-1", "acc-uid-2"]))
        XCTAssertEqual(store.link?.sessionID, "sess-123")
        XCTAssertNotNil(store.link?.consentValidUntil, "access.valid_until parses to a Date")
        XCTAssertNil(store.link?.linkURL, "the pending auth url is cleared once linked")
        XCTAssertNil(store.link?.requisitionID, "the single-use auth-state correlation token is cleared once linked")
    }

    @MainActor
    func testCompleteLinkFailureLeavesStateUnchanged() async throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.post("/sessions", status: 502, json: "{\"error\":\"bad_gateway\"}")])
        let client = EnableBankingClient(session: session, secrets: secrets)
        let store = BankLinkStore(context: context, client: client)

        let state = await store.completeLink(code: "auth-code-1")

        XCTAssertEqual(state, .none, "a failed exchange silently degrades — no partial row is created")
        XCTAssertNil(store.link)
    }

    // MARK: - Unlink

    @MainActor
    func testUnlinkDeletesLinkAttemptsBestEffortDeleteAndWipesKeys() async throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let secrets = BankTestSupport.credentialedSecrets()
        XCTAssertTrue(secrets.hasCredentials)
        let mockSession = MockHTTPSession([.delete("/sessions/sess-1", json: "{}")])
        let client = EnableBankingClient(session: mockSession, secrets: secrets)
        let store = BankLinkStore(context: context, client: client)

        context.insert(BankLink(accountIDs: ["acc-1"], sessionID: "sess-1"))
        try context.save()
        XCTAssertNotNil(store.link)

        await store.unlink()

        XCTAssertNil(store.link, "the link row is deleted")
        XCTAssertFalse(secrets.hasCredentials, "unlink wipes every Keychain secret")
        XCTAssertTrue(
            mockSession.requestLog.contains { $0.method == "DELETE" && $0.path.contains("sessions/sess-1") },
            "unlink attempts a best-effort session delete"
        )
    }

    @MainActor
    func testUnlinkWithNoSessionIDNeverCallsDeleteButStillWipes() async throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let secrets = BankTestSupport.credentialedSecrets()
        let mockSession = MockHTTPSession([])
        let client = EnableBankingClient(session: mockSession, secrets: secrets)
        let store = BankLinkStore(context: context, client: client)

        context.insert(BankLink(authorizationID: "auth-1")) // linkPending, never reached a session
        try context.save()

        await store.unlink()

        XCTAssertNil(store.link)
        XCTAssertFalse(secrets.hasCredentials)
        XCTAssertTrue(mockSession.requestLog.isEmpty, "no session id ⇒ no DELETE is ever attempted")
    }
}
