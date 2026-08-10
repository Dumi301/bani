import XCTest
import SwiftData
@testable import Bani

/// Part A dedup — an auto-logged payment plus its later statement import must
/// collapse through the EXISTING batch-level dedup flow. `.autoLogged` rows join
/// the existing-fingerprint set (alongside `.imported`), so a statement row with
/// the same day+amount+description is caught by `looksAlreadyImported` (default
/// skip). No stored fingerprint on the frozen `Transaction` — it is derived.
@MainActor
final class DedupCollisionTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        try ImportTestSupport.inMemoryContainer().mainContext
    }

    func testAutoLoggedPaymentCollidesWithLaterStatementImport() throws {
        let ctx = try makeContext()
        let day = Date(timeIntervalSince1970: 1_720_000_000)   // fixed day

        // 1) An Apple Pay payment auto-logs itself.
        let tx = try AutoLogWriter.log(
            AutoLogPayload(amountText: "45,00", currencyCode: "RON", merchant: "MEGA IMAGE", date: day),
            in: ctx
        )

        // 2) The same payment later appears as a statement-import row → identical
        //    fingerprint (day + amount + normalized description).
        let existing = ImportBatchStore.existingImportFingerprints(in: ctx)
        let incomingFP = ImportFingerprint.fingerprint(date: tx.date, amount: tx.amount, description: tx.descriptionText)

        XCTAssertTrue(existing.contains(incomingFP), "the auto-logged payment must contribute to the dedup set")
        XCTAssertTrue(ImportFingerprint.looksAlreadyImported(incoming: [incomingFP], existing: existing),
                      "a statement re-import of the auto-logged payment must trip the dedup guard")
    }

    /// Scoping is deliberate: only `.imported` + `.autoLogged` count. A `.voice` or
    /// `.manual` row with the same shape must NOT enter the dedup set (legit
    /// duplicate spend is expected for hand-entered rows).
    func testVoiceAndManualDoNotContributeToDedupSet() throws {
        let ctx = try makeContext()
        let day = Date(timeIntervalSince1970: 1_720_000_000)
        ctx.insert(Transaction(amount: 45, currency: .ron, context: .personal,
                               descriptionText: "MEGA IMAGE", date: day, source: .voice))
        ctx.insert(Transaction(amount: 45, currency: .ron, context: .personal,
                               descriptionText: "MEGA IMAGE", date: day, source: .manual))
        try ctx.save()

        let existing = ImportBatchStore.existingImportFingerprints(in: ctx)
        XCTAssertTrue(existing.isEmpty, "voice/manual rows must not enter the import-dedup set")
    }

    /// Without the auto-logged row present, the same incoming row is NOT flagged.
    func testNoFalsePositiveWithoutPriorAutoLog() throws {
        let ctx = try makeContext()
        let day = Date(timeIntervalSince1970: 1_720_000_000)
        let existing = ImportBatchStore.existingImportFingerprints(in: ctx)
        let incomingFP = ImportFingerprint.fingerprint(date: day, amount: 45, description: "MEGA IMAGE")
        XCTAssertFalse(ImportFingerprint.looksAlreadyImported(incoming: [incomingFP], existing: existing))
    }
}
