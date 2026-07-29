import XCTest
import SwiftData
@testable import Bani

/// A3 — the one-shot cleanup migration: dirty stored fixtures are cleaned,
/// token-artifact learned rules are deleted, seeds and good learned rules are
/// untouched, and the version guard makes it run exactly once.
@MainActor
final class TokenCleanupMigrationTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transaction.self, CategoryRule.self, configurations: config)
        return ModelContext(container)
    }

    func testCleansTransactionsAndDeletesJunkRules() throws {
        let ctx = try makeContext()

        let dirty = Transaction(
            amount: 50, currency: .ron, context: .personal, category: .fuel,
            descriptionText: "<|startoftranscript|><|ro|> benzină",
            rawTranscript: "<|ro|> cincizeci lei benzină", source: .voice
        )
        let clean = Transaction(
            amount: 20, currency: .ron, context: .personal, category: .dining,
            descriptionText: "cafea", rawTranscript: "douăzeci lei cafea", source: .voice
        )
        ctx.insert(dirty)
        ctx.insert(clean)

        ctx.insert(CategoryRule(keyword: "startoftranscript", category: .other, origin: .learned))
        ctx.insert(CategoryRule(keyword: "<|ro|>", category: .fuel, origin: .learned))
        ctx.insert(CategoryRule(keyword: "starbucks", category: .dining, origin: .learned)) // good learned
        ctx.insert(CategoryRule(keyword: "benzina", category: .fuel, origin: .seed))         // seed
        try? ctx.save()

        let summary = TokenCleanupMigration.run(ctx)

        XCTAssertEqual(summary.descriptionsCleaned, 1)
        XCTAssertEqual(summary.transcriptsCleaned, 1)
        XCTAssertEqual(summary.rulesDeleted, 2)

        // Transaction text cleaned, diacritics preserved; clean row untouched.
        XCTAssertEqual(dirty.descriptionText, "benzină")
        XCTAssertFalse(WhisperTokenStripper.containsToken(dirty.rawTranscript ?? ""))
        XCTAssertEqual(clean.descriptionText, "cafea")

        // Junk learned rules gone; good learned + seed survive.
        let keywords = Set((try ctx.fetch(FetchDescriptor<CategoryRule>())).map(\.keyword))
        XCTAssertFalse(keywords.contains("startoftranscript"))
        XCTAssertFalse(keywords.contains("<|ro|>"))
        XCTAssertTrue(keywords.contains("starbucks"))
        XCTAssertTrue(keywords.contains("benzina"))
    }

    func testRunIfNeededIsOneShot() throws {
        let ctx = try makeContext()
        let defaults = UserDefaults(suiteName: "cleanup-test-\(UUID().uuidString)")!

        let first = TokenCleanupMigration.runIfNeeded(ctx, defaults: defaults)
        XCTAssertTrue(first.didRun)

        let second = TokenCleanupMigration.runIfNeeded(ctx, defaults: defaults)
        XCTAssertFalse(second.didRun, "cleanup must run exactly once per install")
    }

    func testIsJunkKeyword() {
        XCTAssertTrue(TokenCleanupMigration.isJunkKeyword("startoftranscript"))
        XCTAssertTrue(TokenCleanupMigration.isJunkKeyword("<|transcribe|>"))
        XCTAssertTrue(TokenCleanupMigration.isJunkKeyword("ro"))     // bare language code
        XCTAssertFalse(TokenCleanupMigration.isJunkKeyword("benzina"))
        XCTAssertFalse(TokenCleanupMigration.isJunkKeyword("restaurant")) // contains no fragment
    }
}
