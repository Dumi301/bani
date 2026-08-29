import Foundation

// MARK: - Decimal <-> String codec (money law: Decimal everywhere, JSON carries a String)

/// `Decimal.description` is locale-independent — always `.` decimal, never
/// grouped (proven house style, see `XLSXWriter.number`). Decoding MUST pass
/// `en_US_POSIX` explicitly: a bare `Decimal(string:)` reads the device's CURRENT
/// locale, and would misparse "0.01" on a comma-decimal locale (RO) — the exact
/// discipline `AmountLexer` / `RuleBasedParser` already document for parsing user
/// input. Never `Double` anywhere in this path (the money law).
enum BackupDecimalCodec {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func encode(_ value: Decimal) -> String { value.description }

    static func decode(_ string: String) throws -> Decimal {
        guard let value = Decimal(string: string, locale: posix) else {
            throw RestoreError.corruptArchive("invalid decimal: \(string)")
        }
        return value
    }

    static func decodeOptional(_ string: String?) throws -> Decimal? {
        guard let string else { return nil }
        return try decode(string)
    }
}

// MARK: - Attachment manifest

/// One attachment's files as they exist under `AttachmentStore.root/<id>/` at
/// backup time — recorded explicitly so `BackupRestorer` never has to enumerate
/// the zip's central directory; every in-archive path is already known and exact
/// (`attachments/<attachmentID>/<file>`).
struct BackupAttachmentEntry: Codable, Equatable, Sendable {
    var attachmentID: UUID
    /// File names inside `attachments/<attachmentID>/` — whatever
    /// `AttachmentStore.save` actually wrote for this id (typically
    /// `original.<ext>`, `extract.txt`, `summary.txt`, `name.txt`), verbatim.
    var files: [String]
}

// MARK: - Per-entity DTOs
//
// One Codable struct per `@Model`, EVERY stored field, in the model's exact
// declared order. Money is `Decimal` encoded as a `String` (never `Double`).
// Every other field mirrors the literal STORED property (not a computed
// accessor) so legacy-nil rows round-trip byte-for-byte — the ONE sanctioned
// exception is `Transaction.direction` (see its doc below), matching the
// approved P1 design notes.

/// Mirrors `Transaction` (`Bani/Models/Transaction.swift`).
struct TransactionDTO: Codable, Equatable, Sendable {
    var id: UUID
    var amount: String
    var currency: Currency
    var context: TransactionContext
    var category: TransactionCategory?
    var customCategoryID: UUID?
    var descriptionText: String
    var merchant: String?
    var date: Date
    var rawTranscript: String?
    var source: TransactionSource
    /// The PUBLIC computed accessor, NOT `directionStored` — the one sanctioned
    /// exception (P1 design notes item 2): the accessor already defaults a
    /// legacy-NULL row to `.expense`, `direction` is never used in a
    /// `#Predicate`/`SortDescriptor` keypath anywhere in the app (all direction
    /// filtering is in-memory), so writing `.expense` back on restore for a
    /// legacy-nil row is behaviorally lossless — the restored row reads
    /// identically to the original in every code path that touches it.
    var direction: TransactionDirection
    var counterparty: String?
    var attachmentID: UUID?
    var importBatchID: UUID?
    var projectID: UUID?
    var loanID: UUID?
    var duplicateOfID: UUID?
    var createdAt: Date

    init(_ tx: Transaction) {
        id = tx.id
        amount = BackupDecimalCodec.encode(tx.amount)
        currency = tx.currency
        context = tx.context
        category = tx.category
        customCategoryID = tx.customCategoryID
        descriptionText = tx.descriptionText
        merchant = tx.merchant
        date = tx.date
        rawTranscript = tx.rawTranscript
        source = tx.source
        direction = tx.direction
        counterparty = tx.counterparty
        attachmentID = tx.attachmentID
        importBatchID = tx.importBatchID
        projectID = tx.projectID
        loanID = tx.loanID
        duplicateOfID = tx.duplicateOfID
        createdAt = tx.createdAt
    }

    func makeModel() throws -> Transaction {
        Transaction(
            id: id, amount: try BackupDecimalCodec.decode(amount), currency: currency,
            context: context, category: category, customCategoryID: customCategoryID,
            descriptionText: descriptionText, merchant: merchant, date: date,
            rawTranscript: rawTranscript, source: source, direction: direction,
            counterparty: counterparty, attachmentID: attachmentID, importBatchID: importBatchID,
            projectID: projectID, loanID: loanID, duplicateOfID: duplicateOfID, createdAt: createdAt
        )
    }
}

/// Mirrors `CategoryRule` (`Bani/Models/CategoryRule.swift`).
struct CategoryRuleDTO: Codable, Equatable, Sendable {
    var id: UUID
    var keyword: String
    var category: TransactionCategory
    var customCategoryID: UUID?
    var origin: CategoryRuleOrigin
    var hitCount: Int
    var updatedAt: Date

    init(_ rule: CategoryRule) {
        id = rule.id
        keyword = rule.keyword
        category = rule.category
        customCategoryID = rule.customCategoryID
        origin = rule.origin
        hitCount = rule.hitCount
        updatedAt = rule.updatedAt
    }

    func makeModel() -> CategoryRule {
        CategoryRule(id: id, keyword: keyword, category: category, customCategoryID: customCategoryID,
                     origin: origin, hitCount: hitCount, updatedAt: updatedAt)
    }
}

/// Mirrors `DecisionRecord` (`Bani/Feedback/DecisionRecord.swift`).
struct DecisionRecordDTO: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var transactionID: UUID?
    var guessedCategory: TransactionCategory?
    var guessedContext: TransactionContext
    var firedRuleID: UUID?
    var refinedText: String
    var outcome: DecisionOutcome
    /// The literal stored `Int` — `CorrectedFields(rawValue:)` never fails/never
    /// drops bits, so this is already a full-fidelity mirror of the OptionSet.
    var correctedFieldsRaw: Int
    var latencySeconds: Double

    init(_ record: DecisionRecord) {
        id = record.id
        createdAt = record.createdAt
        transactionID = record.transactionID
        guessedCategory = record.guessedCategory
        guessedContext = record.guessedContext
        firedRuleID = record.firedRuleID
        refinedText = record.refinedText
        outcome = record.outcome
        correctedFieldsRaw = record.correctedFieldsRaw
        latencySeconds = record.latencySeconds
    }

    func makeModel() -> DecisionRecord {
        DecisionRecord(id: id, createdAt: createdAt, transactionID: transactionID,
                        guessedCategory: guessedCategory, guessedContext: guessedContext,
                        firedRuleID: firedRuleID, refinedText: refinedText, outcome: outcome,
                        correctedFields: CorrectedFields(rawValue: correctedFieldsRaw),
                        latencySeconds: latencySeconds)
    }
}

/// Mirrors `ContextRule` (`Bani/Feedback/ContextRule.swift`).
struct ContextRuleDTO: Codable, Equatable, Sendable {
    var id: UUID
    var keyword: String
    var context: TransactionContext
    var confirmations: Int
    var updatedAt: Date

    init(_ rule: ContextRule) {
        id = rule.id
        keyword = rule.keyword
        context = rule.context
        confirmations = rule.confirmations
        updatedAt = rule.updatedAt
    }

    func makeModel() -> ContextRule {
        ContextRule(id: id, keyword: keyword, context: context, confirmations: confirmations, updatedAt: updatedAt)
    }
}

/// Mirrors `CorrectionMemory` (`Bani/Feedback/CorrectionMemory.swift`).
struct CorrectionMemoryDTO: Codable, Equatable, Sendable {
    var id: UUID
    var normalizedRawTranscript: String
    var correctedDescription: String
    var updatedAt: Date

    init(_ memory: CorrectionMemory) {
        id = memory.id
        normalizedRawTranscript = memory.normalizedRawTranscript
        correctedDescription = memory.correctedDescription
        updatedAt = memory.updatedAt
    }

    func makeModel() -> CorrectionMemory {
        CorrectionMemory(id: id, normalizedRawTranscript: normalizedRawTranscript,
                          correctedDescription: correctedDescription, updatedAt: updatedAt)
    }
}

/// Mirrors `CustomCategory` (`Bani/Models/CustomCategory.swift`).
struct CustomCategoryDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var symbolName: String
    var colorIndex: Int
    var createdAt: Date

    init(_ category: CustomCategory) {
        id = category.id
        name = category.name
        symbolName = category.symbolName
        colorIndex = category.colorIndex
        createdAt = category.createdAt
    }

    func makeModel() -> CustomCategory {
        CustomCategory(id: id, name: name, symbolName: symbolName, colorIndex: colorIndex, createdAt: createdAt)
    }
}

/// Mirrors `ImportBatch` (`Bani/Models/ImportBatch.swift`).
struct ImportBatchDTO: Codable, Equatable, Sendable {
    var id: UUID
    var fileName: String
    var importedAt: Date
    var rowCount: Int
    var skippedCount: Int
    var contextChoice: String
    var notes: String

    init(_ batch: ImportBatch) {
        id = batch.id
        fileName = batch.fileName
        importedAt = batch.importedAt
        rowCount = batch.rowCount
        skippedCount = batch.skippedCount
        contextChoice = batch.contextChoice
        notes = batch.notes
    }

    func makeModel() -> ImportBatch {
        ImportBatch(id: id, fileName: fileName, importedAt: importedAt, rowCount: rowCount,
                    skippedCount: skippedCount, contextChoice: contextChoice, notes: notes)
    }
}

/// Mirrors `Project` (`Bani/Models/Project.swift`).
struct ProjectDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var status: ProjectStatus
    var colorIndex: Int
    var sortOrder: Int
    var archived: Bool
    var createdAt: Date

    init(_ project: Project) {
        id = project.id
        name = project.name
        status = project.status
        colorIndex = project.colorIndex
        sortOrder = project.sortOrder
        archived = project.archived
        createdAt = project.createdAt
    }

    func makeModel() -> Project {
        Project(id: id, name: name, status: status, colorIndex: colorIndex,
                sortOrder: sortOrder, archived: archived, createdAt: createdAt)
    }
}

/// Mirrors `Person` (`Bani/Models/Person.swift`).
struct PersonDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var normalizedName: String
    /// The literal `kindRaw` stored string, not the `kind` computed accessor —
    /// avoids any silent drift through `PersonKind(rawValue:)` for a hypothetical
    /// future/unknown raw value.
    var kindRaw: String?
    var notes: String?
    var createdAt: Date

    init(_ person: Person) {
        id = person.id
        name = person.name
        normalizedName = person.normalizedName
        kindRaw = person.kindRaw
        notes = person.notes
        createdAt = person.createdAt
    }

    func makeModel() -> Person {
        let person = Person(id: id, name: name, normalizedName: normalizedName, kind: nil, notes: notes, createdAt: createdAt)
        person.kindRaw = kindRaw
        return person
    }
}

/// Mirrors `ScheduledItem` (`Bani/Models/ScheduledItem.swift`).
struct ScheduledItemDTO: Codable, Equatable, Sendable {
    var id: UUID
    var direction: ScheduledDirection
    var amount: String
    var currency: Currency
    var title: String
    var descriptionText: String
    var counterparty: String?
    var dueDate: Date
    var projectID: UUID?
    var status: ScheduledStatus
    var linkedTransactionID: UUID?
    /// The literal `recurrenceRaw` stored optional String, not the `recurrence`
    /// computed accessor — mirrors the `Person.kindRaw` discipline, so a legacy
    /// (pre-recurrence) row's true `nil` round-trips rather than being rewritten
    /// to the `.none` rawValue string.
    var recurrenceRaw: String?
    var seriesID: UUID?
    var loanID: UUID?
    /// Follow-up 2 (v2.2 phase C): the literal `scheduleIndexRaw` stored Int? —
    /// additive + optional, same discipline as `recurrenceRaw`: a pre-M3 archive
    /// has no such key, and Swift's synthesized `Decodable` decodes a missing key
    /// on an Optional property to `nil` automatically, so old archives round-trip
    /// with no stamp (falling back to due-date booking order), never a decode
    /// failure.
    var scheduleIndex: Int?
    var createdAt: Date

    init(_ item: ScheduledItem) {
        id = item.id
        direction = item.direction
        amount = BackupDecimalCodec.encode(item.amount)
        currency = item.currency
        title = item.title
        descriptionText = item.descriptionText
        counterparty = item.counterparty
        dueDate = item.dueDate
        projectID = item.projectID
        status = item.status
        linkedTransactionID = item.linkedTransactionID
        recurrenceRaw = item.recurrenceRaw
        seriesID = item.seriesID
        loanID = item.loanID
        scheduleIndex = item.scheduleIndexRaw
        createdAt = item.createdAt
    }

    func makeModel() throws -> ScheduledItem {
        let item = ScheduledItem(
            id: id, direction: direction, amount: try BackupDecimalCodec.decode(amount), currency: currency,
            title: title, descriptionText: descriptionText, counterparty: counterparty, dueDate: dueDate,
            projectID: projectID, status: status, linkedTransactionID: linkedTransactionID,
            seriesID: seriesID, loanID: loanID, scheduleIndex: scheduleIndex, createdAt: createdAt
        )
        item.recurrenceRaw = recurrenceRaw
        return item
    }
}

/// Mirrors `BalanceAnchor` (`Bani/Models/BalanceAnchor.swift`).
struct BalanceAnchorDTO: Codable, Equatable, Sendable {
    var id: UUID
    var amount: String
    var currency: Currency
    var anchoredAt: Date
    var driftAtAnchor: String
    var note: String?
    /// L3: the literal `unresolvedResidualRaw` stored optional Decimal (encoded
    /// String, same discipline as `amount`/`driftAtAnchor`) — `nil` for every
    /// anchor closed by an adjustment and for a pre-L3 archive (a missing key
    /// decodes to `nil` via Swift's synthesized `Decodable`, matching how
    /// `ScheduledItemDTO.scheduleIndex` round-trips a legacy archive).
    var unresolvedResidual: String?
    var createdAt: Date

    init(_ anchor: BalanceAnchor) {
        id = anchor.id
        amount = BackupDecimalCodec.encode(anchor.amount)
        currency = anchor.currency
        anchoredAt = anchor.anchoredAt
        driftAtAnchor = BackupDecimalCodec.encode(anchor.driftAtAnchor)
        note = anchor.note
        unresolvedResidual = anchor.unresolvedResidualRaw.map(BackupDecimalCodec.encode)
        createdAt = anchor.createdAt
    }

    func makeModel() throws -> BalanceAnchor {
        BalanceAnchor(
            id: id, amount: try BackupDecimalCodec.decode(amount), currency: currency,
            anchoredAt: anchoredAt, driftAtAnchor: try BackupDecimalCodec.decode(driftAtAnchor),
            note: note, unresolvedResidual: try BackupDecimalCodec.decodeOptional(unresolvedResidual),
            createdAt: createdAt
        )
    }
}

/// Mirrors `Loan` (`Bani/Models/Loan.swift`).
struct LoanDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var lender: String
    /// The literal `kindRaw` stored string, not the `kind` accessor — same
    /// no-silent-fallback discipline as `Person.kindRaw`.
    var kindRaw: String
    var principal: String
    var currency: Currency
    var annualRatePercent: String?
    var startDate: Date
    var termMonths: Int?
    var fixedMonthlyPayment: String?
    var projectID: UUID?
    /// The literal `statusRaw` stored string, not the `status` accessor.
    var statusRaw: String
    var notes: String
    var createdAt: Date

    init(_ loan: Loan) {
        id = loan.id
        name = loan.name
        lender = loan.lender
        kindRaw = loan.kindRaw
        principal = BackupDecimalCodec.encode(loan.principal)
        currency = loan.currency
        annualRatePercent = loan.annualRatePercent.map(BackupDecimalCodec.encode)
        startDate = loan.startDate
        termMonths = loan.termMonths
        fixedMonthlyPayment = loan.fixedMonthlyPayment.map(BackupDecimalCodec.encode)
        projectID = loan.projectID
        statusRaw = loan.statusRaw
        notes = loan.notes
        createdAt = loan.createdAt
    }

    func makeModel() throws -> Loan {
        let loan = Loan(
            id: id, name: name, lender: lender, kind: .bank, principal: try BackupDecimalCodec.decode(principal),
            currency: currency, annualRatePercent: try BackupDecimalCodec.decodeOptional(annualRatePercent),
            startDate: startDate, termMonths: termMonths,
            fixedMonthlyPayment: try BackupDecimalCodec.decodeOptional(fixedMonthlyPayment),
            projectID: projectID, status: .active, notes: notes, createdAt: createdAt
        )
        loan.kindRaw = kindRaw
        loan.statusRaw = statusRaw
        return loan
    }
}

/// Mirrors `BankLink` (`Bani/Banking/BankLinkStore.swift`). Holds ONLY the
/// non-secret metadata the model itself stores — no secret ever lives here, same
/// as the live `@Model` (secrets stay in the Keychain, out of scope for backup).
struct BankLinkDTO: Codable, Equatable, Sendable {
    var id: UUID
    var institutionID: String?
    var institutionName: String?
    var agreementID: String?
    var requisitionID: String?
    var statusCode: String?
    var accountIDs: [String]
    var agreementExpiresAt: Date?
    var linkURL: String?
    var lastSyncByAccount: [String: Date]
    var createdAt: Date

    init(_ link: BankLink) {
        id = link.id
        institutionID = link.institutionID
        institutionName = link.institutionName
        agreementID = link.agreementID
        requisitionID = link.requisitionID
        statusCode = link.statusCode
        accountIDs = link.accountIDs
        agreementExpiresAt = link.agreementExpiresAt
        linkURL = link.linkURL
        lastSyncByAccount = link.lastSyncByAccount
        createdAt = link.createdAt
    }

    func makeModel() -> BankLink {
        BankLink(id: id, institutionID: institutionID, institutionName: institutionName,
                 agreementID: agreementID, requisitionID: requisitionID, statusCode: statusCode,
                 accountIDs: accountIDs, agreementExpiresAt: agreementExpiresAt, linkURL: linkURL,
                 lastSyncByAccount: lastSyncByAccount, createdAt: createdAt)
    }
}
