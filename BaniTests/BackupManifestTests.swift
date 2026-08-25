import XCTest
import SwiftData
@testable import Bani

/// `BackupManifest` coverage (P1): the Codable shape (a clean keyed JSON object,
/// not the flat array `Dictionary<BackupEntity, Int>` would produce), a full
/// round trip through `Codable`, counts matching a real seeded archive, and the
/// `formatVersion` gate rejecting an archive from a future format.
final class BackupManifestTests: XCTestCase {

    // MARK: - Shape / Codable round trip

    func testManifestJSONIsAKeyedObjectNotAFlatArray() throws {
        let manifest = BackupManifest(appBuild: "42", counts: [.transaction: 3, .loan: 1])
        let encoder = JSONEncoder()
        let data = try encoder.encode(manifest)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        XCTAssertEqual(counts["transaction"] as? Int, 3)
        XCTAssertEqual(counts["loan"] as? Int, 1)
        // Every other entity defaults to 0 via the subscript, but is simply
        // ABSENT from the encoded dictionary — never written for a 0 count.
        XCTAssertNil(counts["project"])
    }

    func testManifestRoundTripsThroughCodable() throws {
        let seededCounts = Dictionary(uniqueKeysWithValues: BackupEntity.allCases.map { ($0, 5) })
        let manifest = BackupManifest(appBuild: "7", counts: seededCounts)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: data)

        XCTAssertEqual(decoded.formatVersion, BackupManifest.currentFormatVersion)
        XCTAssertEqual(decoded.appBuild, "7")
        for entity in BackupEntity.allCases {
            XCTAssertEqual(decoded[entity], 5, "\(entity) count did not round-trip")
        }
        XCTAssertEqual(decoded.totalRowCount, 5 * BackupEntity.allCases.count)
    }

    func testSubscriptDefaultsToZeroForAnUnsetEntity() {
        let manifest = BackupManifest(appBuild: "1", counts: [.transaction: 9])
        XCTAssertEqual(manifest[.transaction], 9)
        XCTAssertEqual(manifest[.bankLink], 0)
    }

    // MARK: - Counts match a real seeded archive

    @MainActor
    func testManifestCountsMatchSeededCounts() async throws {
        // Needs multi-entity coverage (every entity > 0 below) but NOT the
        // on-disk legacy-nil replica — a plain in-memory container with the same
        // rich seed data.
        let sourceContainer = try BackupTestFixtures.makeInMemorySeededContainer()
        let archiver = BackupArchiver(modelContainer: sourceContainer)
        let archive = try await archiver.makeArchive()

        let peekContainer = try BaniModelContainer.make(inMemory: true)
        let restorer = BackupRestorer(modelContainer: peekContainer)
        let manifest = try await restorer.peekManifest(archive: archive)

        let ctx = ModelContext(sourceContainer)
        XCTAssertEqual(manifest[.transaction], try ctx.fetchCount(FetchDescriptor<Transaction>()))
        XCTAssertEqual(manifest[.categoryRule], try ctx.fetchCount(FetchDescriptor<CategoryRule>()))
        XCTAssertEqual(manifest[.decisionRecord], try ctx.fetchCount(FetchDescriptor<DecisionRecord>()))
        XCTAssertEqual(manifest[.contextRule], try ctx.fetchCount(FetchDescriptor<ContextRule>()))
        XCTAssertEqual(manifest[.correctionMemory], try ctx.fetchCount(FetchDescriptor<CorrectionMemory>()))
        XCTAssertEqual(manifest[.customCategory], try ctx.fetchCount(FetchDescriptor<CustomCategory>()))
        XCTAssertEqual(manifest[.importBatch], try ctx.fetchCount(FetchDescriptor<ImportBatch>()))
        XCTAssertEqual(manifest[.project], try ctx.fetchCount(FetchDescriptor<Project>()))
        XCTAssertEqual(manifest[.person], try ctx.fetchCount(FetchDescriptor<Person>()))
        XCTAssertEqual(manifest[.scheduledItem], try ctx.fetchCount(FetchDescriptor<ScheduledItem>()))
        XCTAssertEqual(manifest[.balanceAnchor], try ctx.fetchCount(FetchDescriptor<BalanceAnchor>()))
        XCTAssertEqual(manifest[.loan], try ctx.fetchCount(FetchDescriptor<Loan>()))
        XCTAssertEqual(manifest[.bankLink], try ctx.fetchCount(FetchDescriptor<BankLink>()))

        // Non-vacuous: every entity actually has at least one seeded row, so this
        // test cannot pass by every count coincidentally being 0.
        for entity in BackupEntity.allCases {
            XCTAssertGreaterThan(manifest[entity], 0, "\(entity) has no seeded rows — the fixture is missing coverage")
        }
    }

    // MARK: - Version gate

    @MainActor
    func testVersionGateRejectsFutureFormat() async throws {
        // A minimal, hand-built archive containing ONLY a manifest with a
        // formatVersion this build doesn't understand — no entity files needed,
        // since the version gate must reject BEFORE any row is read.
        let futureManifest = BackupManifest(formatVersion: BackupManifest.currentFormatVersion + 1, appBuild: "1", counts: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970 // matches BackupRestorer's decoder
        let manifestData = try encoder.encode(futureManifest)
        let archive = StoreZipWriter.archive([StoreZipWriter.Entry(path: "manifest.json", data: manifestData)])

        let container = try BaniModelContainer.make(inMemory: true)
        let restorer = BackupRestorer(modelContainer: container)
        do {
            _ = try await restorer.restore(archive: archive)
            XCTFail("expected RestoreError.unsupportedVersion")
        } catch RestoreError.unsupportedVersion(let found, let supported) {
            XCTAssertEqual(found, BackupManifest.currentFormatVersion + 1)
            XCTAssertEqual(supported, BackupManifest.currentFormatVersion)
        }

        // Nothing was touched — the gate rejected before any entity fetch/insert.
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Transaction>()).count, 0)
    }

    @MainActor
    func testCurrentFormatVersionIsAccepted() async throws {
        // Plain in-memory source — just needs a valid archive; the on-disk
        // legacy-nil replica is irrelevant to the version gate.
        let sourceContainer = try BaniModelContainer.make(inMemory: true)
        let sourceContext = ModelContext(sourceContainer)
        sourceContext.insert(Transaction(amount: 25, currency: .ron, context: .personal, descriptionText: "sursă", source: .manual))
        try sourceContext.save()

        let archiver = BackupArchiver(modelContainer: sourceContainer)
        let archive = try await archiver.makeArchive()

        let container = try BaniModelContainer.make(inMemory: true)
        let restorer = BackupRestorer(modelContainer: container)
        let manifest = try await restorer.restore(archive: archive)
        XCTAssertEqual(manifest.formatVersion, BackupManifest.currentFormatVersion)
    }
}
