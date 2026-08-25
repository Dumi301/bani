import XCTest
import SwiftData
@testable import Bani

/// P9 — the end-to-end bank pull, off the main actor, landing in the EXISTING
/// auto-log review flow. Fixture-only (no network, no keys). Proves: pulled
/// transactions become `.autoLogged` rows with the correct fields and appear in
/// `AutoLogReview.unreviewed`; a second overlapping pull inserts nothing (bank-key
/// dedup); a planted cross-source duplicate is P8-flagged (never dropped); and with
/// no keys the whole thing is inert (no network touched, nothing inserted).
@MainActor
final class BankSyncTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer { try BaniModelContainer.make(inMemory: true) }

    private func ronSession(reusable: Bool = true) -> MockHTTPSession {
        MockHTTPSession([.get("/accounts/acc-ron-1/transactions/", json: BankFixtures.transactionsRON, reusable: reusable)])
    }

    // MARK: - Pull lands in the review flow with correct fields

    func testPullLandsDraftsInAutoLogReviewWithCorrectFields() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = GoCardlessClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], accountCurrency: .ron, client: client)

        XCTAssertEqual(outcome.inserted, 3)
        XCTAssertEqual(outcome.accountsSynced, 1)

        let ctx = ModelContext(container)
        let review = AutoLogReview.unreviewed(in: ctx)
        XCTAssertEqual(review.count, 3, "every pulled transaction lands in the auto-log review chip")
        XCTAssertTrue(review.allSatisfy { $0.source == .autoLogged })

        // tx-1 — a debit (expense) with a creditor name, mapped from the STRING amount.
        let lidl = try XCTUnwrap(review.first { $0.counterparty == "Lidl Cluj" })
        XCTAssertEqual(lidl.amount, Decimal(string: "15.30"))
        XCTAssertEqual(lidl.currency, .ron)
        XCTAssertEqual(lidl.direction, .expense)
        XCTAssertEqual(lidl.date, BankFixtures.bookingDate("2026-08-20"))
        XCTAssertNotNil(lidl.categoryRef, "category is annotated (deterministic on CI)")
        XCTAssertTrue(lidl.rawTranscript?.hasPrefix("[bank]") == true, "verbatim, bank-origin tagged")

        // tx-2 — a credit (income) with a debtor name; direction comes from the sign.
        let salary = try XCTUnwrap(review.first { $0.counterparty == "ACME SRL" })
        XCTAssertEqual(salary.direction, .income)
        XCTAssertEqual(salary.amount, Decimal(string: "328.18"))
    }

    // MARK: - Second overlapping pull → no double-insert

    func testSecondOverlappingPullDoesNotDoubleInsert() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = GoCardlessClient(session: ronSession(reusable: true), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let first = await service.sync(accountIDs: ["acc-ron-1"], client: client)
        let second = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertEqual(first.inserted, 3)
        XCTAssertEqual(second.inserted, 0, "the same bank transactions are never re-inserted")
        XCTAssertEqual(second.skippedDuplicates, 3)

        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
        XCTAssertEqual(all.count, 3, "still exactly three rows after the overlapping re-pull")
    }

    // MARK: - Cross-source P8 flagging

    func testBankRowFlaggedAgainstManualDuplicate() async throws {
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = GoCardlessClient(session: ronSession(), secrets: secrets)
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

        XCTAssertEqual(outcome.inserted, 3, "flagging never blocks the save (never-drop law)")
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
        let client = GoCardlessClient(session: session, secrets: secrets)
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
        let client = GoCardlessClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let seed = ModelContext(container)
        let link = BankLink(agreementID: "a-1", statusCode: "LN", accountIDs: ["acc-ron-1"])
        seed.insert(link)
        try seed.save()

        _ = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        let ctx = ModelContext(container)
        let stored = try XCTUnwrap((try? ctx.fetch(FetchDescriptor<BankLink>()))?.first)
        // Last-sync advances to at least the newest EXPLICIT booking date (tx-2,
        // 2026-08-21). The date-less bare row falls back to "now", which is later
        // still — so assert the floor, not an exact value.
        let lastSync = try XCTUnwrap(stored.lastSyncByAccount["acc-ron-1"])
        XCTAssertGreaterThanOrEqual(lastSync, BankFixtures.bookingDate("2026-08-21"))
    }
}
