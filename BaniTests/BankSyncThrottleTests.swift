import XCTest
import SwiftData
@testable import Bani

/// H1 — the foreground bank-sync throttle (`BankSyncGate`) + L4 — the hardened
/// `BankSyncMapper.parseAmount` separator disambiguation.
///
/// The gate tests use a dedicated `UserDefaults` suite (never `.standard`) so
/// they are fully isolated from any other test/run — `BankSyncGate` is
/// injectable exactly for this reason (mirrors `RateService`'s `@AppStorage`
/// pattern, but as a plain testable type; see `BankSyncGate`'s doc comment).
@MainActor
final class BankSyncThrottleTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BankSyncThrottleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer { try BaniModelContainer.make(inMemory: true) }

    private func ronSession(reusable: Bool = true) -> MockHTTPSession {
        MockHTTPSession([.get("/accounts/acc-ron-1/transactions", json: BankFixtures.transactionsMixed, reusable: reusable)])
    }

    private func failingSession() -> MockHTTPSession {
        MockHTTPSession([.get("/accounts/acc-ron-1/transactions", status: 500, json: "{}", reusable: true)])
    }

    // MARK: - (a) Sync skipped inside the interval

    func testShouldSyncFalseInsideInterval() {
        let gate = BankSyncGate(defaults: defaults)
        let now = Date()
        gate.recordOutcome(BankSyncOutcome(inserted: 3, accountsSynced: 1), now: now)

        XCTAssertFalse(gate.shouldSync(now: now.addingTimeInterval(1)))
        XCTAssertFalse(gate.shouldSync(now: now.addingTimeInterval(BankSyncGate.minInterval - 1)))
    }

    // MARK: - (b) Runs after the interval elapsed

    func testShouldSyncTrueAfterIntervalElapsed() {
        let gate = BankSyncGate(defaults: defaults)
        let now = Date()
        gate.recordOutcome(BankSyncOutcome(inserted: 3, accountsSynced: 1), now: now)

        XCTAssertTrue(gate.shouldSync(now: now.addingTimeInterval(BankSyncGate.minInterval)))
        XCTAssertTrue(gate.shouldSync(now: now.addingTimeInterval(BankSyncGate.minInterval + 1)))
    }

    /// Never having synced at all is also a "should sync" state (first run).
    func testShouldSyncTrueWhenNeverSynced() {
        let gate = BankSyncGate(defaults: defaults)
        XCTAssertNil(gate.lastSuccessAt)
        XCTAssertTrue(gate.shouldSync())
    }

    // MARK: - (c) Manual trigger bypasses the gate

    func testManualSyncBypassesGateAndStillInserts() async throws {
        let gate = BankSyncGate(defaults: defaults)
        let now = Date()
        // Simulate "just synced" — the opportunistic path would be gated shut.
        gate.recordOutcome(BankSyncOutcome(inserted: 1, accountsSynced: 1), now: now)
        XCTAssertFalse(gate.shouldSync(now: now.addingTimeInterval(60)), "sanity: gate IS shut")

        // The manual path (mirrors `BankLinkView.syncNow()`) never consults
        // `shouldSync` — it calls `BankSyncService.sync` directly.
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: ronSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)

        XCTAssertEqual(outcome.inserted, 4, "manual sync runs and inserts regardless of the gate's state (4 BOOK rows in the fixture, the PEND row excluded)")
    }

    // MARK: - (d) Failed sync does not advance the persisted timestamp

    func testFailedOutcomeDoesNotAdvanceTimestamp() {
        let gate = BankSyncGate(defaults: defaults)
        XCTAssertNil(gate.lastSuccessAt)

        let failed = BankSyncOutcome(accountsSynced: 0, hadError: true)
        gate.recordOutcome(failed, now: Date())

        XCTAssertNil(gate.lastSuccessAt, "a failed attempt never sets lastSuccessAt")
        XCTAssertTrue(gate.lastHadError)
        // So the very next foreground check is NOT blocked — it retries.
        XCTAssertTrue(gate.shouldSync())
    }

    /// A failed attempt after a PRIOR success must not clobber the earlier
    /// timestamp either — it just leaves it exactly where it was.
    func testFailedOutcomeAfterPriorSuccessLeavesTimestampUntouched() {
        let gate = BankSyncGate(defaults: defaults)
        let firstSuccess = Date().addingTimeInterval(-1000)
        gate.recordOutcome(BankSyncOutcome(inserted: 2, accountsSynced: 1), now: firstSuccess)
        XCTAssertEqual(gate.lastSuccessAt, firstSuccess)

        gate.recordOutcome(BankSyncOutcome(accountsSynced: 0, hadError: true), now: Date())

        XCTAssertEqual(gate.lastSuccessAt, firstSuccess, "the failure did not move the last-success timestamp")
        XCTAssertTrue(gate.lastHadError)
    }

    /// End-to-end: a real failing sync (500 from the transactions endpoint)
    /// through the gate, confirming the gate stays open for an immediate retry.
    func testEndToEndFailingSyncLeavesGateOpenForRetry() async throws {
        let gate = BankSyncGate(defaults: defaults)
        let container = try makeContainer()
        let secrets = BankTestSupport.credentialedSecrets()
        let client = EnableBankingClient(session: failingSession(), secrets: secrets)
        let service = BankSyncService(modelContainer: container)

        XCTAssertTrue(gate.shouldSync())
        let outcome = await service.sync(accountIDs: ["acc-ron-1"], client: client)
        XCTAssertTrue(outcome.hadError)
        gate.recordOutcome(outcome)

        XCTAssertNil(gate.lastSuccessAt)
        XCTAssertTrue(gate.shouldSync(), "next foreground check retries immediately, not after a full 6h wait")
    }

    /// A `credentialsMissing` (inert) outcome is a no-op for the gate — it must
    /// not be mistaken for either a success or a failure.
    func testCredentialsMissingOutcomeIsIgnored() {
        let gate = BankSyncGate(defaults: defaults)
        gate.recordOutcome(.inert)

        XCTAssertNil(gate.lastSuccessAt)
        XCTAssertFalse(gate.lastHadError)
    }

    // MARK: - L4: BankSyncMapper.parseAmount

    func testParseAmountThousandsAndDecimalTogetherDotDecimal() {
        let result = BankSyncMapper.parseAmount("1,234.56")
        XCTAssertEqual(result?.magnitude, Decimal(string: "1234.56"))
        XCTAssertEqual(result?.direction, .income)
    }

    func testParseAmountCommaDecimalOnly() {
        let result = BankSyncMapper.parseAmount("1234,56")
        XCTAssertEqual(result?.magnitude, Decimal(string: "1234.56"))
        XCTAssertEqual(result?.direction, .income)
    }

    /// The regression this bug is about: a bare "1,234" is thousands-grouped
    /// (1234), NOT a decimal (1.234) — the naive comma→dot swap got this wrong.
    func testParseAmountCommaAsThousandsSeparatorNotDecimal() {
        let result = BankSyncMapper.parseAmount("1,234")
        XCTAssertEqual(result?.magnitude, Decimal(1234))
        XCTAssertEqual(result?.direction, .income)
    }

    func testParseAmountNegativeDotDecimal() {
        let result = BankSyncMapper.parseAmount("-12.30")
        XCTAssertEqual(result?.magnitude, Decimal(string: "12.30"))
        XCTAssertEqual(result?.direction, .expense)
    }

    /// The plain dot-decimal shape (still `BankSyncMapper.parseAmount`'s own
    /// general-purpose contract, even though `draft(from:)` no longer routes
    /// Enable Banking's unsigned amounts through it) — must parse exactly as
    /// before this fix (behavior-preserving for existing inputs).
    func testParseAmountPlainDotDecimalUnchanged() {
        let result = BankSyncMapper.parseAmount("12.30")
        XCTAssertEqual(result?.magnitude, Decimal(string: "12.30"))
        XCTAssertEqual(result?.direction, .income)
    }
}
