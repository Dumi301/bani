import Foundation

/// Every entity this backup covers — the full v2 `BaniModelContainer.schema` set
/// (13 entities: the original 9 plus `Person`, `BalanceAnchor`, `Loan`, `BankLink`).
/// A 14th entity later is mechanical: one new case + one new DTO + one new
/// Archiver/Restorer block (P1 design notes item 2 — "structure DTOs so adding an
/// entity later is mechanical").
enum BackupEntity: String, Codable, CaseIterable, Hashable, Sendable {
    case transaction, categoryRule, decisionRecord, contextRule, correctionMemory
    case customCategory, importBatch, project, person, scheduledItem
    case balanceAnchor, loan, bankLink

    /// The in-archive JSON file name for this entity's row array — the single
    /// source of truth `BackupArchiver` writes to and `BackupRestorer` reads from,
    /// so the two can never drift out of sync on a hand-typed literal.
    var fileName: String { "\(rawValue).json" }
}

extension BackupEntity {
    /// Localized display label for the restore-summary alert / erase-confirm
    /// dialog (Bani/Localizable.xcstrings `backup.entity.*`).
    var label: String {
        switch self {
        case .transaction: String(localized: "backup.entity.transaction")
        case .categoryRule: String(localized: "backup.entity.categoryRule")
        case .decisionRecord: String(localized: "backup.entity.decisionRecord")
        case .contextRule: String(localized: "backup.entity.contextRule")
        case .correctionMemory: String(localized: "backup.entity.correctionMemory")
        case .customCategory: String(localized: "backup.entity.customCategory")
        case .importBatch: String(localized: "backup.entity.importBatch")
        case .project: String(localized: "backup.entity.project")
        case .person: String(localized: "backup.entity.person")
        case .scheduledItem: String(localized: "backup.entity.scheduledItem")
        case .balanceAnchor: String(localized: "backup.entity.balanceAnchor")
        case .loan: String(localized: "backup.entity.loan")
        case .bankLink: String(localized: "backup.entity.bankLink")
        }
    }
}

/// The archive's header — validated before any row is touched (the `formatVersion`
/// gate in `BackupRestorer`), then the source of truth for the restore summary
/// (per-entity row counts) and the erase-and-restore confirmation.
struct BackupManifest: Codable, Equatable, Sendable {
    /// Bump ONLY on a breaking change to the DTO/archive shape. Additive DTO
    /// fields (a 14th entity, a new optional column on an existing one) do NOT
    /// need a bump — `BackupRestorer` rejects only `formatVersion > current`.
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var appBuild: String
    /// Row counts keyed by `BackupEntity.rawValue`. Deliberately `[String: Int]`,
    /// not `[BackupEntity: Int]`: `Dictionary`'s synthesized `Encodable` only
    /// emits a clean keyed JSON object when `Key == String` (or `Int`) — a
    /// `BackupEntity` key would encode as a flat `[key, value, key, value, …]`
    /// array instead, which is valid Codable but an ugly, harder-to-inspect
    /// on-disk shape for a manifest a user might one day open in a text editor.
    /// Every call site still reads/writes through the typed `subscript` below,
    /// so nothing outside this file ever touches a raw string key.
    var counts: [String: Int]

    init(formatVersion: Int = BackupManifest.currentFormatVersion, createdAt: Date = .now, appBuild: String, counts: [BackupEntity: Int]) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appBuild = appBuild
        self.counts = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }

    /// Typed accessor — the only way call sites read/write a count.
    subscript(entity: BackupEntity) -> Int {
        get { counts[entity.rawValue] ?? 0 }
        set { counts[entity.rawValue] = newValue }
    }

    /// Total rows across every entity — the restore-confirm dialog's `%lld`.
    var totalRowCount: Int { BackupEntity.allCases.reduce(0) { $0 + self[$1] } }
}
