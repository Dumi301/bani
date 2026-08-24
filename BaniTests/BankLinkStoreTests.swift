import XCTest
import SwiftData
@testable import Bani

/// P9 — the requisition lifecycle state machine (`BankLinkState.derive`). Pure and
/// source-free, so every transition is asserted without network or the Keychain.
/// Also proves the additive `BankLink` `@Model` registers migration-safely in the
/// production schema (an in-memory `BaniModelContainer` carrying the FULL schema).
final class BankLinkStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000) // fixed clock

    private func snap(
        agreement: String? = nil, requisition: String? = nil,
        status: RequisitionStatus? = nil, accounts: [String] = [], expires: Date? = nil
    ) -> BankLinkSnapshot {
        BankLinkSnapshot(agreementID: agreement, requisitionID: requisition, status: status, accountIDs: accounts, agreementExpiresAt: expires)
    }

    // MARK: - Transitions

    func testNoneWhenNothingStarted() {
        XCTAssertEqual(BankLinkState.derive(from: snap(), now: now), .none)
    }

    func testAgreementCreatedWhenAgreementButNoRequisitionStatus() {
        let state = BankLinkState.derive(from: snap(agreement: "a-1"), now: now)
        XCTAssertEqual(state, .agreementCreated)
    }

    func testLinkPendingForCreatedAndInProgressStatuses() {
        for status: RequisitionStatus in [.created, .givingConsent, .undergoingAuth, .selectingAccounts, .grantingAccess] {
            let state = BankLinkState.derive(from: snap(agreement: "a-1", requisition: "r-1", status: status), now: now)
            XCTAssertEqual(state, .linkPending, "status \(status) should be linkPending")
        }
    }

    func testLinkedWhenLNWithAccounts() {
        let state = BankLinkState.derive(
            from: snap(agreement: "a-1", requisition: "r-1", status: .linked, accounts: ["acc-1", "acc-2"], expires: now.addingTimeInterval(86_400)),
            now: now
        )
        XCTAssertEqual(state, .linked(accountIDs: ["acc-1", "acc-2"]))
        XCTAssertTrue(state.isLinked)
        XCTAssertEqual(state.accountIDs, ["acc-1", "acc-2"])
    }

    func testLinkedButNoAccountsFallsBackToPending() {
        let state = BankLinkState.derive(
            from: snap(agreement: "a-1", requisition: "r-1", status: .linked, accounts: [], expires: now.addingTimeInterval(86_400)),
            now: now
        )
        XCTAssertEqual(state, .linkPending)
    }

    // MARK: - Expiry → re-link

    func testExpiredWhenAgreementWindowPassedEvenIfStatusStillLinked() {
        // A stale LN status must NOT mask an expired agreement window.
        let state = BankLinkState.derive(
            from: snap(agreement: "a-1", requisition: "r-1", status: .linked, accounts: ["acc-1"], expires: now.addingTimeInterval(-1)),
            now: now
        )
        XCTAssertEqual(state, .expired)
        XCTAssertTrue(state.needsRelink)
    }

    func testExpiredForTerminalStatuses() {
        for status: RequisitionStatus in [.expired, .suspended, .rejected] {
            let state = BankLinkState.derive(from: snap(agreement: "a-1", requisition: "r-1", status: status), now: now)
            XCTAssertEqual(state, .expired, "status \(status) should require a re-link")
            XCTAssertTrue(status.needsRelink)
        }
    }

    func testUnknownStatusIsTreatedAsPendingNotExpired() {
        // A feed quirk (unrecognized code) must never trip a premature expiry.
        let state = BankLinkState.derive(from: snap(agreement: "a-1", requisition: "r-1", status: .unknown), now: now)
        XCTAssertEqual(state, .linkPending)
    }

    func testRequisitionStatusTolerantInit() {
        XCTAssertEqual(RequisitionStatus(code: "LN"), .linked)
        XCTAssertEqual(RequisitionStatus(code: "EX"), .expired)
        XCTAssertEqual(RequisitionStatus(code: "ZZ"), .unknown)
        XCTAssertEqual(RequisitionStatus(code: nil), .unknown)
    }

    // MARK: - Persisted model round-trip (proves additive schema registration)

    @MainActor
    func testBankLinkModelPersistsAndDerivesState() throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let link = BankLink(
            institutionID: "BANCA_TRANSILVANIA_BTRLRO22",
            institutionName: "Banca Transilvania",
            agreementID: "agreement-123",
            requisitionID: "req-123",
            statusCode: "LN",
            accountIDs: ["acc-eur-1", "acc-ron-1"],
            agreementExpiresAt: now.addingTimeInterval(90 * 86_400)
        )
        context.insert(link)
        try context.save()

        let fetched = try XCTUnwrap((try? context.fetch(FetchDescriptor<BankLink>()))?.first)
        XCTAssertEqual(fetched.accountIDs, ["acc-eur-1", "acc-ron-1"])
        XCTAssertEqual(BankLinkState.derive(from: fetched.snapshot, now: now), .linked(accountIDs: ["acc-eur-1", "acc-ron-1"]))
    }

    @MainActor
    func testUnlinkDeletesLinkAndWipesKeys() throws {
        let context = ModelContext(try BaniModelContainer.make(inMemory: true))
        let secrets = BankTestSupport.credentialedSecrets()
        XCTAssertTrue(secrets.hasCredentials)
        let client = GoCardlessClient(session: MockHTTPSession([]), secrets: secrets)
        let store = BankLinkStore(context: context, client: client)

        context.insert(BankLink(agreementID: "a-1", statusCode: "LN", accountIDs: ["acc-1"]))
        try context.save()
        XCTAssertNotNil(store.link)

        store.unlink()

        XCTAssertNil(store.link, "the link row is deleted")
        XCTAssertFalse(secrets.hasCredentials, "unlink wipes every Keychain secret")
        XCTAssertNil(secrets.value(TokenBundle.self, for: .tokenBundle), "the cached token is wiped too")
    }
}
