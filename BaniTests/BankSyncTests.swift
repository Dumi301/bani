import XCTest
import SwiftData
@testable import Bani

/// P9 / v2.3 — the end-to-end bank pull against `EnableBankingClient`, off the
/// main actor, landing in the EXISTING auto-log review flow. Fixture-only (no
/// network, no keys). Proves: pulled `BOOK` transactions become `.autoLogged`
/// rows with the correct fields (a `PEND` row is never landed); a second
/// overlapping pull inserts nothing (bank-key dedup); a planted cross-source
/// duplicate is P8-flagged (never dropped); with no keys the whole thing is
/// inert (no network touched, nothing inserted); a `continuation_key` pagination
/// walk lands rows from every page; a pre-v2.3 marker never false-collides with
/// a freshly computed v2.3 bank key; and a 403 from `transactions` marks the
/// link's session revoked.
@MainActor
final class BankSyncTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer { try BaniModelContainer.make(inMemory: true) }

    private func ronSession(reusable: Bool = true) -> MockHTTPSession {
        MockHTTPSession([.get("/accounts/acc-ron-1/transactions", json: BankFixtures.transactionsMixed, reusable: reusable)])
    }

    private func pagedSession() -> MockHTTPSession {
        MockHTTPSession([
            .get("/accounts/acc-ron-1/transactions", json: BankFixtures.transactionsPage1),
            .get("/accounts/acc-ron-1/transactions", json: BankFixtures.transactionsPage2),
        ])
    }

    private func forbiddenSession() -> MockHTTPSession {
        MockHTTPSession([.get("/accounts/acc-ron-1/transactions", status: 403, json: "{\"error\":\"forbidden\"}", reusable: true)])
    }

    /// `transactionsMixed` has 5 rows; ONE (`tx-3`, Uber) is `PEND` and is never
    /// landed — so every "whole fixture" assertion expects 4, not 5.
    private let expectedBookedCount = 4

    // MARK: - Pull lands in the review flow with correct fields

    func testPullLandsDraftsInAutoLogReviewWithCorrectFields() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], accountCurrency: .ron, client: client)

        XCTAssertEqual(outcome.inserted, expectedBookedCount)
        XCTAssertEqual(outcome.accountsSynced, 1)

        let ctx = ModelContext(container)
        let review = AutoLogReview.unreviewed(in: ctx)
        XCTAssertEqual(review.count, expectedBookedCount, "every pulled BOOK transaction lands in the auto-log review chip")
        XCTAssertTrue(review.allSatisfy { $0.source == .autoLogged })

        // tx-2 — a debit (expense) with a creditor name, mapped from the UNSIGNED amount string.
        let lidl = try XCTUnwrap(review.first { $0.counterparty == "Lidl Cluj" })
        XCTAssertEqual(lidl.amount, Decimal(string: "15.30"))
        XCTAssertEqual(lidl.currency, .ron)
        XCTAssertEqual(lidl.direction, .expense)
        XCTAssertEqual(lidl.date, BankFixtures.bookingDate("2026-08-20"))
        XCTAssertNotNil(lidl.categoryRef, "category is annotated (deterministic on CI)")
        XCTAssertTrue(lidl.rawTranscript?.hasPrefix("[bank]") == true, "verbatim, bank-origin tagged")

        // tx-1 — a credit (income) with a debtor name; direction comes from credit_debit_indicator, never a sign.
        let salary = try XCTUnwrap(review.first { $0.counterparty == "ACME SRL" })
        XCTAssertEqual(salary.direction, .income)
        XCTAssertEqual(salary.amount, Decimal(string: "328.18"))
    }

    // MARK: - PEND row is skipped

    func testPendingRowIsNeverLanded() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        _ = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        XCTAssertNil(all.first { $0.counterparty == "Uber" }, "a PEND status row (tx-3) is never landed")
        XCTAssertEqual(all.count, expectedBookedCount)
    }

    // MARK: - Second overlapping pull → no double-insert

    func testSecondOverlappingPullDoesNotDoubleInsert() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(reusable: true), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let first = await service.sync(accountIDs: ["acc-ron-1"], client: client)
        let second = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertEqual(first.inserted, expectedBookedCount)
        XCTAssertEqual(second.inserted, 0, "the same bank transactions are never re-inserted")
        XCTAssertEqual(second.skippedDuplicates, expectedBookedCount)

        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        XCTAssertEqual(all.count, expectedBookedCount, "still exactly the same rows after the overlapping re-pull")
    }

    // MARK: - Cross-source P8 flagging

    func testBankRowFlaggedAgainstManualDuplicate() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        // Plant a MANUAL entry of the same coffee before the pull.
        let seed = ModelContext(container)
        let manual = Transaction(
            amount: Decimal(string: "15.30")!, currency: .ron, context: .personal,
            descriptionText: "Lidl", merchant: "Lidl", date: BankFixtures.bookingDate("2026-08-20"),
            source: .manual, direction: .expense
        )
        seed.insert(manual)
        try seed.save()
        let manualID = manual.id

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertEqual(outcome.inserted, expectedBookedCount, "flagging never blocks the save (never-drop law)")
        XCTAssertGreaterThanOrEqual(outcome.flaggedCrossSource, 1)

        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        let bankLidl = try XCTUnwrap(all.first { $0.source == .autoLogged && $0.counterparty == "Lidl Cluj" })
        XCTAssertEqual(bankLidl.duplicateOfID, manualID, "the bank row is flagged as a possible duplicate of the manual one")
        // The manual row is untouched (never dropped).
        XCTAssertNotNil(all.first { $0.id == manualID })
    }

    // MARK: - No keys → inert

    func testNoKeysIsInertNoNetworkNoInserts() async throws {
        let container = try makeContainer()
        let secrets = InMemorySecretStore() // empty — no keys
        let session = ronSession()
        let client = EnableBankingClient(session: session, secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertTrue(outcome.credentialsMissing)
        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertTrue(session.requestLog.isEmpty, "no keys ⇒ the network is never touched")

        let ctx = ModelContext(container)
        XCTAssertEqual(AutoLogReview.unreviewed(in: ctx).count, 0)
    }

    // MARK: - Since-last-sync bookkeeping

    func testLastSyncBookkeepingRecordsNewestBooking() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let seed = ModelContext(container)
        let link = BankLink(accountIDs: ["acc-ron-1"], sessionID: "sess-1")
        seed.insert(link)
        try seed.save()

        _ = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        let ctx = ModelContext(container)
        let stored = try XCTUnwrap((try? ctx.fetch(FetchDescriptor<BankLink>()))?.first)
        // Last-sync advances to at least the newest EXPLICIT booking date (tx-1,
        // 2026-08-21). The date-less rows fall back to "now", which is later
        // still — so assert the floor, not an exact value.
        let lastSync = try XCTUnwrap(stored.lastSyncByAccount["acc-ron-1"])
        XCTAssertGreaterThanOrEqual(lastSync, BankFixtures.bookingDate("2026-08-21"))
    }

    // MARK: - (a) Pagination walk inserts rows from both pages

    func testContinuationKeyPaginationWalkInsertsRowsFromBothPages() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: pagedSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertEqual(outcome.inserted, 2, "both pages' rows land")
        XCTAssertEqual(outcome.accountsSynced, 1, "one account, walked across two pages")

        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        XCTAssertEqual(Set(all.compactMap(\.counterparty)), ["Page One Merchant", "Page Two Merchant"])
    }

    // MARK: - (c) No-collision regression: a pre-v2.3 marker never false-collides

    func testPreV23EraMarkerNeverFalseCollidesWithFreshlyComputedV23BankKeys() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        // Plant a pre-v2.3 (GoCardless-era) row: its marker embeds an opaque
        // GoCardless-shaped id that the v2.3 (Enable Banking) mapper could never
        // itself produce — the synthetic-fingerprint FORMAT is unchanged
        // (`syn:<date>|<amount>|<currency>|<counterparty>`), but real distinct
        // transaction data still yields a distinct key either way. Proves
        // `extractBankKey`/`seenKeys` still work correctly across the marker
        // format's continuity, and that the legacy row is never touched by a
        // v2.3 sync.
        let seed = ModelContext(container)
        let legacy = Transaction(
            amount: Decimal(string: "50.00")!, currency: .ron, context: .personal,
            descriptionText: "Legacy bank row", date: BankFixtures.bookingDate("2026-01-01"),
            rawTranscript: "[bank] Legacy bank row 50.00 RON ⟦bank:req-gocardless-legacy-9f3a⟧",
            source: .autoLogged, direction: .expense
        )
        seed.insert(legacy)
        try seed.save()
        let legacyID = legacy.id
        let legacyTranscript = legacy.rawTranscript

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertEqual(outcome.inserted, expectedBookedCount, "every fresh v2.3 row inserts — no false collision with the legacy marker")
        XCTAssertEqual(outcome.skippedDuplicates, 0, "the legacy key never matches a freshly computed v2.3 bankKey")

        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        XCTAssertEqual(all.count, expectedBookedCount + 1, "the legacy row plus every freshly pulled v2.3 row")
        let stillThere = try XCTUnwrap(all.first { $0.id == legacyID })
        XCTAssertEqual(stillThere.rawTranscript, legacyTranscript, "the legacy row is untouched by the v2.3 sync")
    }

    // MARK: - (d) 403 sets sessionRevoked

    func testForbiddenResponseFromTransactionsSetsSessionRevoked() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: forbiddenSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let seed = ModelContext(container)
        let link = BankLink(accountIDs: ["acc-ron-1"], sessionID: "sess-1")
        seed.insert(link)
        try seed.save()

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertTrue(outcome.hadError)
        let ctx = ModelContext(container)
        let stored = try XCTUnwrap((try? ctx.fetch(FetchDescriptor<BankLink>()))?.first)
        XCTAssertEqual(stored.sessionRevoked, true)
    }

    func testUnauthorizedResponseFromTransactionsAlsoSetsSessionRevoked() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let session = MockHTTPSession([.get("/accounts/acc-ron-1/transactions", status: 401, json: "{\"error\":\"unauthorized\"}", reusable: true)])
        let client = EnableBankingClient(session: session, secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let seed = ModelContext(container)
        let link = BankLink(accountIDs: ["acc-ron-1"], sessionID: "sess-1")
        seed.insert(link)
        try seed.save()

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertTrue(outcome.hadError)
        let ctx = ModelContext(container)
        let stored = try XCTUnwrap((try? ctx.fetch(FetchDescriptor<BankLink>()))?.first)
        XCTAssertEqual(stored.sessionRevoked, true, "defensively both 401 and 403 mark the session revoked")
    }
}
