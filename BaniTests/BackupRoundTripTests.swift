import XCTest
import SwiftData
@testable import Bani

/// Full-fidelity backup/restore coverage (P1): every entity in the 13-entity v2
/// schema, Decimal edge amounts (0.01 and a huge value), nil AND non-nil
/// optionals, a legacy-nil-`direction` row (the `DirectionNullMigrationTests`
/// parallel-schema trick against a REAL on-disk store — the only way to prove a
/// genuine on-disk `NULL` round-trips), an attachment blob, and RO diacritics
/// throughout string fields.
@MainActor
final class BackupRoundTripTests: XCTestCase {

    // MARK: - Full round trip

    func testFullFidelityRoundTrip() async throws {
        let seed = try BackupTestFixtures.makeSeededContainer()
        let sourceContext = ModelContext(seed.container)

        // Sanity: the legacy row really does fault `directionStored` to nil —
        // proving the round trip below exercises the real legacy path, not a
        // row that merely happens to hold `.expense`.
        let legacyBefore = try XCTUnwrap(
            try sourceContext.fetch(FetchDescriptor<Transaction>()).first { $0.id == seed.legacyDirectionID }
        )
        XCTAssertEqual(legacyBefore.direction, .expense, "legacy NULL direction already reads .expense pre-backup")

        let archiver = BackupArchiver(modelContainer: seed.container)
        let archive = try await archiver.makeArchive(appBuild: "99")

        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let restorer = BackupRestorer(modelContainer: targetContainer)
        let manifest = try await restorer.restore(archive: archive)

        XCTAssertEqual(manifest.appBuild, "99")
        XCTAssertEqual(manifest.formatVersion, BackupManifest.currentFormatVersion)

        let targetContext = ModelContext(targetContainer)

        // Field-identical equality per row, entity by entity — every DTO mirrors
        // every stored property, so comparing DTOs built from BOTH sides is a
        // literal "compare stored properties" check.
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<Transaction>()), try targetContext.fetch(FetchDescriptor<Transaction>()),
                         id: \.id, dto: TransactionDTO.init, entity: "Transaction")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<CategoryRule>()), try targetContext.fetch(FetchDescriptor<CategoryRule>()),
                         id: \.id, dto: CategoryRuleDTO.init, entity: "CategoryRule")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<DecisionRecord>()), try targetContext.fetch(FetchDescriptor<DecisionRecord>()),
                         id: \.id, dto: DecisionRecordDTO.init, entity: "DecisionRecord")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<ContextRule>()), try targetContext.fetch(FetchDescriptor<ContextRule>()),
                         id: \.id, dto: ContextRuleDTO.init, entity: "ContextRule")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<CorrectionMemory>()), try targetContext.fetch(FetchDescriptor<CorrectionMemory>()),
                         id: \.id, dto: CorrectionMemoryDTO.init, entity: "CorrectionMemory")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<CustomCategory>()), try targetContext.fetch(FetchDescriptor<CustomCategory>()),
                         id: \.id, dto: CustomCategoryDTO.init, entity: "CustomCategory")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<ImportBatch>()), try targetContext.fetch(FetchDescriptor<ImportBatch>()),
                         id: \.id, dto: ImportBatchDTO.init, entity: "ImportBatch")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<Project>()), try targetContext.fetch(FetchDescriptor<Project>()),
                         id: \.id, dto: ProjectDTO.init, entity: "Project")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<Person>()), try targetContext.fetch(FetchDescriptor<Person>()),
                         id: \.id, dto: PersonDTO.init, entity: "Person")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<ScheduledItem>()), try targetContext.fetch(FetchDescriptor<ScheduledItem>()),
                         id: \.id, dto: ScheduledItemDTO.init, entity: "ScheduledItem")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<BalanceAnchor>()), try targetContext.fetch(FetchDescriptor<BalanceAnchor>()),
                         id: \.id, dto: BalanceAnchorDTO.init, entity: "BalanceAnchor")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<Loan>()), try targetContext.fetch(FetchDescriptor<Loan>()),
                         id: \.id, dto: LoanDTO.init, entity: "Loan")
        assertRowsMatch(try sourceContext.fetch(FetchDescriptor<BankLink>()), try targetContext.fetch(FetchDescriptor<BankLink>()),
                         id: \.id, dto: BankLinkDTO.init, entity: "BankLink")

        // The legacy-nil row restores reading .expense too (behaviorally lossless).
        let legacyAfter = try XCTUnwrap(
            try targetContext.fetch(FetchDescriptor<Transaction>()).first { $0.id == seed.legacyDirectionID }
        )
        XCTAssertEqual(legacyAfter.direction, .expense)

        // The attachment blob round-trips: bytes + extracted text + summary + filename.
        let hugeTx = try XCTUnwrap(
            try targetContext.fetch(FetchDescriptor<Transaction>()).first { $0.descriptionText == BackupTestFixtures.hugeDescription }
        )
        let attachmentID = try XCTUnwrap(hugeTx.attachmentID)
        XCTAssertEqual(AttachmentStore.originalFileName(id: attachmentID), "contract.pdf")
        XCTAssertEqual(AttachmentStore.extractedText(id: attachmentID), "extracted text")
        XCTAssertEqual(AttachmentStore.summary(id: attachmentID), "rezumat cu diacritice: ăâîșț")
        let originalURL = try XCTUnwrap(AttachmentStore.originalURL(id: attachmentID))
        XCTAssertEqual(try Data(contentsOf: originalURL), BackupTestFixtures.attachmentBytes)
    }

    // MARK: - Guard rails

    func testRestoreIntoNonEmptyStoreThrows() async throws {
        let seed = try BackupTestFixtures.makeSeededContainer()
        let archiver = BackupArchiver(modelContainer: seed.container)
        let archive = try await archiver.makeArchive()

        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let targetContext = ModelContext(targetContainer)
        targetContext.insert(Transaction(amount: 1, currency: .ron, context: .personal, descriptionText: "existing", source: .manual))
        try targetContext.save()

        let restorer = BackupRestorer(modelContainer: targetContainer)
        do {
            _ = try await restorer.restore(archive: archive)
            XCTFail("expected RestoreError.storeNotEmpty")
        } catch RestoreError.storeNotEmpty(let counts) {
            XCTAssertEqual(counts[.transaction], 1)
        }

        // The store is untouched by the failed restore — still exactly the 1
        // pre-existing row, none of the archive's rows landed.
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<Transaction>()).count, 1)
    }

    func testEraseAndRestoreReplacesExistingData() async throws {
        let seed = try BackupTestFixtures.makeSeededContainer()
        let archiver = BackupArchiver(modelContainer: seed.container)
        let archive = try await archiver.makeArchive()
        let sourceTransactionCount = try ModelContext(seed.container).fetch(FetchDescriptor<Transaction>()).count

        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let targetContext = ModelContext(targetContainer)
        let staleID = UUID()
        targetContext.insert(Transaction(id: staleID, amount: 1, currency: .ron, context: .personal, descriptionText: "stale", source: .manual))
        try targetContext.save()

        let restorer = BackupRestorer(modelContainer: targetContainer)
        let manifest = try await restorer.eraseAndRestore(archive: archive)

        XCTAssertEqual(manifest[.transaction], sourceTransactionCount)
        let rows = try targetContext.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, sourceTransactionCount)
        XCTAssertFalse(rows.contains { $0.id == staleID }, "the stale pre-existing row is gone")
    }

    func testCorruptArchiveThrowsAndStoreIsUntouched() async throws {
        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let targetContext = ModelContext(targetContainer)
        targetContext.insert(Transaction(amount: 1, currency: .ron, context: .personal, descriptionText: "safe", source: .manual))
        try targetContext.save()

        let restorer = BackupRestorer(modelContainer: targetContainer)
        do {
            _ = try await restorer.restore(archive: Data("not a zip archive at all".utf8))
            XCTFail("expected RestoreError.corruptArchive")
        } catch RestoreError.corruptArchive {
            // expected
        }
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<Transaction>()).count, 1, "store untouched by a corrupt archive")
    }

    func testTruncatedArchiveThrowsAndStoreIsUntouched() async throws {
        let seed = try BackupTestFixtures.makeSeededContainer()
        let archiver = BackupArchiver(modelContainer: seed.container)
        let archive = try await archiver.makeArchive()
        // Chop the archive in half — the end-of-central-directory record (always
        // at the tail) is gone, so the reader can never locate the zip's index.
        let truncated = Data(archive.prefix(archive.count / 2))

        let targetContainer = try BaniModelContainer.make(inMemory: true)
        let restorer = BackupRestorer(modelContainer: targetContainer)
        do {
            _ = try await restorer.restore(archive: truncated)
            XCTFail("expected an error decoding a truncated archive")
        } catch {
            // any thrown error is acceptable — the load-bearing guarantee below
            // is that the store stays untouched.
        }
        XCTAssertEqual(try ModelContext(targetContainer).fetch(FetchDescriptor<Transaction>()).count, 0, "store untouched by a truncated archive")
    }

    // MARK: - Comparison helper

    private func assertRowsMatch<Model, DTO: Equatable>(
        _ source: [Model], _ target: [Model],
        id: (Model) -> UUID, dto: (Model) -> DTO, entity: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let sourceByID = Dictionary(uniqueKeysWithValues: source.map { (id($0), dto($0)) })
        let targetByID = Dictionary(uniqueKeysWithValues: target.map { (id($0), dto($0)) })
        XCTAssertEqual(sourceByID.count, targetByID.count, "\(entity): row count differs", file: file, line: line)
        for (key, sourceDTO) in sourceByID {
            XCTAssertEqual(sourceDTO, targetByID[key], "\(entity) \(key) is not field-identical after restore", file: file, line: line)
        }
    }
}

// MARK: - Legacy shape (file scope, ONE level of nesting — mirrors the proven
// `DirectionNullMigrationTests.LegacyStoreV26` idiom exactly)

/// The pre-v1.1 `Transaction` shape — no `direction`/`counterparty`/
/// `attachmentID`/`importBatchID`/`projectID`/`loanID`/`duplicateOfID` columns at
/// all. Nested in an enum so its SwiftData entity name is still `"Transaction"`
/// (the same on-disk table as `Bani.Transaction`) while the Swift type stays
/// distinct — the standard versioned-schema idiom this codebase already uses in
/// `DirectionNullMigrationTests`.
private enum BackupLegacyStoreV26 {
    @Model final class Transaction {
        var id: UUID
        var amount: Decimal
        var currency: Currency
        var context: TransactionContext
        var descriptionText: String
        var source: TransactionSource
        var createdAt: Date

        init(id: UUID = UUID(), amount: Decimal, currency: Currency, context: TransactionContext,
             descriptionText: String, source: TransactionSource, createdAt: Date = .now) {
            self.id = id
            self.amount = amount
            self.currency = currency
            self.context = context
            self.descriptionText = descriptionText
            self.source = source
            self.createdAt = createdAt
        }
    }
}

// MARK: - Shared fixtures (also used by BackupManifestTests, same target)

/// Seeds one row of every entity in the 13-entity v2 schema, covering: Decimal
/// edge amounts (0.01 and a huge value), nil AND non-nil optionals, a legacy-nil
/// `direction` row, an attachment blob, and RO diacritics.
enum BackupTestFixtures {

    static let hugeDescription = "Tranzacție uriașă"
    static let attachmentBytes = Data("PDF-BYTES-CONTRACT".utf8)

    private static func freshOnDiskURL(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bani-backup-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    @MainActor
    static func makeSeededContainer() throws -> (container: ModelContainer, legacyDirectionID: UUID) {
        let url = try freshOnDiskURL("seed")
        let legacyID = UUID()

        // 1. Write ONE row with the pre-v1.1 shape — this store has NO
        //    `direction` column at all.
        do {
            let legacyContainer = try ModelContainer(for: BackupLegacyStoreV26.Transaction.self, configurations: ModelConfiguration(url: url))
            let ctx = legacyContainer.mainContext
            ctx.insert(BackupLegacyStoreV26.Transaction(id: legacyID, amount: 10, currency: .ron, context: .personal,
                                                          descriptionText: "legacy expense", source: .manual))
            try ctx.save()
        }

        // 2. Reopen the SAME store URL with the CURRENT 13-entity schema — the
        //    legacy row's `directionStored` faults to a real on-disk NULL.
        let container = try ModelContainer(for: BaniModelContainer.schema, configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)

        // 3. Seed one of every other entity, with edge Decimals, nil/non-nil
        //    optionals, an attachment blob, and RO diacritics throughout.
        let attachmentID = UUID()
        AttachmentStore.save(id: attachmentID, originalData: attachmentBytes, originalFileName: "contract.pdf",
                              extractedText: "extracted text", summary: "rezumat cu diacritice: ăâîșț")

        let customCategory = CustomCategory(name: "Călătorii", symbolName: "airplane", colorIndex: 2)
        ctx.insert(customCategory)

        let project = Project(name: "Proiect Alfa Șt.", colorIndex: 1)
        ctx.insert(project)

        let person = Person(name: "Ștefan Popescu", normalizedName: "stefan popescu", kind: .client,
                             notes: "note cu diacritice: ăâîșț")
        ctx.insert(person)

        let personNoKindOrNotes = Person(name: "Anonim", normalizedName: "anonim", kind: nil, notes: nil)
        ctx.insert(personNoKindOrNotes)

        let importBatch = ImportBatch(fileName: "extras bancar.csv", rowCount: 2, skippedCount: 1,
                                       contextChoice: "personal", notes: "notă de proveniență")
        ctx.insert(importBatch)

        let loan = Loan(name: "Credit ipotecar", lender: "Bancă Națională", kind: .bank,
                         principal: 250_000.00, annualRatePercent: 7.9, termMonths: 240,
                         projectID: project.id, notes: "notă despre credit")
        ctx.insert(loan)

        let interestFreeLoan = Loan(name: "Împrumut fără dobândă", lender: "Investitor X", kind: .investor,
                                     principal: 5_000, annualRatePercent: nil, termMonths: nil,
                                     fixedMonthlyPayment: nil, projectID: nil, notes: "")
        ctx.insert(interestFreeLoan)

        let scheduled = ScheduledItem(direction: .outgoing, amount: 0.01, currency: .ron, title: "Rată",
                                       counterparty: "Bancă Națională", dueDate: .now, projectID: project.id,
                                       recurrence: .monthly, loanID: loan.id)
        ctx.insert(scheduled)

        let scheduledMinimal = ScheduledItem(direction: .incoming, amount: 42, currency: .eur, title: "Plată client", dueDate: .now)
        ctx.insert(scheduledMinimal)

        let anchor = BalanceAnchor(amount: 12_345.67, currency: .eur, driftAtAnchor: -0.01, note: "notă ancoră")
        ctx.insert(anchor)

        let anchorNoNote = BalanceAnchor(amount: 0.01, currency: .ron, driftAtAnchor: 0, note: nil)
        ctx.insert(anchorNoNote)

        let bankLink = BankLink(institutionID: "revolut_ro", institutionName: "Revolut", agreementID: "agr-1",
                                 requisitionID: "req-1", statusCode: "LN", accountIDs: ["acc-1", "acc-2"],
                                 agreementExpiresAt: Date().addingTimeInterval(86_400), linkURL: nil,
                                 lastSyncByAccount: ["acc-1": Date()])
        ctx.insert(bankLink)

        let rule = CategoryRule(keyword: "benzina", category: .fuel, origin: .learned, hitCount: 5)
        ctx.insert(rule)

        let ruleWithCustom = CategoryRule(keyword: "bilet avion", category: .other, customCategoryID: customCategory.id, origin: .learned)
        ctx.insert(ruleWithCustom)

        let contextRule = ContextRule(keyword: "salariu", context: .work, confirmations: 4)
        ctx.insert(contextRule)

        let correction = CorrectionMemory(normalizedRawTranscript: "cafea 12 lei", correctedDescription: "Cafea la birou — mulțumesc ăâîșț")
        ctx.insert(correction)

        let decision = DecisionRecord(guessedCategory: .fuel, guessedContext: .personal, firedRuleID: rule.id,
                                       refinedText: "text rafinat cu diacritice ăâîșț", outcome: .corrected,
                                       correctedFields: [.amount, .category])
        ctx.insert(decision)

        let discardedDecision = DecisionRecord(guessedCategory: nil, guessedContext: .work, outcome: .discarded)
        ctx.insert(discardedDecision)

        // The huge-value, fully-populated Transaction (carries the attachment).
        let hugeTx = Transaction(
            amount: 99_999_999_999_999.99, currency: .eur, context: .work,
            customCategoryID: customCategory.id, descriptionText: hugeDescription,
            merchant: "Măgazin Ștefan", date: .now, rawTranscript: "am cheltuit foarte mult azi",
            source: .voice, direction: .income, counterparty: "Ștefan Popescu",
            attachmentID: attachmentID, importBatchID: importBatch.id,
            projectID: project.id, loanID: loan.id, duplicateOfID: nil
        )
        ctx.insert(hugeTx)

        // The 0.01-amount, minimally-populated Transaction (every optional nil).
        let tinyTx = Transaction(amount: 0.01, currency: .ron, context: .personal,
                                  category: .groceries, descriptionText: "Pâine",
                                  source: .manual, direction: .expense)
        ctx.insert(tinyTx)

        // A neutral transaction flagged as a possible duplicate of the huge one.
        let dupTx = Transaction(amount: 42, currency: .ron, context: .personal,
                                 descriptionText: "posibil duplicat", source: .imported,
                                 direction: .neutral, duplicateOfID: hugeTx.id)
        ctx.insert(dupTx)

        try ctx.save()
        return (container, legacyID)
    }
}
