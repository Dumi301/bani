import Foundation
import SwiftData

// MARK: - Domain enums (Phase-0 FROZEN — workers reference, never edit)

/// Supported currencies. Raw value is the ISO-ish display code.
enum Currency: String, Codable, CaseIterable, Hashable, Sendable {
    case ron = "RON"
    case eur = "EUR"

    var displayCode: String { rawValue }
    var symbol: String {
        switch self {
        case .ron: "lei"
        case .eur: "€"
        }
    }
}

/// The two life contexts a transaction belongs to.
enum TransactionContext: String, Codable, CaseIterable, Hashable, Sendable {
    case personal
    case work

    /// Localized display name (B1) — the stored `rawValue` is unchanged.
    var label: String {
        switch self {
        case .personal: String(localized: "context.personal")
        case .work: String(localized: "context.work")
        }
    }

    /// Semantic tag color asset name for this context.
    var tagColorName: String {
        switch self {
        case .personal: "BaniTagPersonal"
        case .work: "BaniTagWork"
        }
    }
}

/// Preset spending categories. Extensible for later AI categorization.
enum TransactionCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case fuel, groceries, dining, transport, utilities, shopping, health, entertainment, other

    /// Localized display name (B1) — the stored `rawValue` is unchanged, so
    /// existing data and the categorizer keep working on the raw enum.
    var label: String {
        switch self {
        case .fuel: String(localized: "category.fuel")
        case .groceries: String(localized: "category.groceries")
        case .dining: String(localized: "category.dining")
        case .transport: String(localized: "category.transport")
        case .utilities: String(localized: "category.utilities")
        case .shopping: String(localized: "category.shopping")
        case .health: String(localized: "category.health")
        case .entertainment: String(localized: "category.entertainment")
        case .other: String(localized: "category.other")
        }
    }
    var systemImage: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .groceries: "cart.fill"
        case .dining: "fork.knife"
        case .transport: "bus.fill"
        case .utilities: "bolt.fill"
        case .shopping: "bag.fill"
        case .health: "cross.case.fill"
        case .entertainment: "gamecontroller.fill"
        case .other: "square.grid.2x2.fill"
        }
    }
}

/// How a transaction was created.
///
/// v1.1 adds ONE case: `imported` (Excel/CSV history import). Migration-safety:
/// SwiftData persists this `String`-raw `Codable` enum as its `rawValue`, so the
/// addition only widens the set of *valid* values — it never rewrites the stored
/// "voice"/"manual" strings existing rows already hold, and decoding those is
/// unchanged. Same additive discipline as the `customCategoryID` precedent; no
/// heavyweight migration, existing data untouched (proven in
/// `ImportModelMigrationTests`).
enum TransactionSource: String, Codable, CaseIterable, Hashable, Sendable {
    case voice
    case manual
    case imported
}

// MARK: - SwiftData model

/// The single persisted entity. Money is ALWAYS `Decimal`, never `Double`.
/// `rawTranscript` is stored verbatim for voice entries and never discarded
/// (v2 semantic search depends on it).
@Model
final class Transaction {
    var id: UUID
    var amount: Decimal
    var currency: Currency
    var context: TransactionContext
    var category: TransactionCategory?
    /// C1 — the SINGLE sanctioned exception to the frozen seam: an optional
    /// reference to a user-defined `CustomCategory`. When set it takes precedence
    /// over `category` (see `Transaction.categoryRef`). Additive + optional, so
    /// this stays a lightweight SwiftData migration — existing rows migrate to
    /// `nil` and survive untouched.
    var customCategoryID: UUID?
    var descriptionText: String
    var merchant: String?
    var date: Date
    var rawTranscript: String?
    var source: TransactionSource
    /// v1.1 — the batch an imported row belongs to (`ImportBatch.id`), enabling a
    /// whole-batch undo. `nil` for every non-imported transaction. A nullable,
    /// additive field, so this is a lightweight SwiftData migration (mirrors the
    /// `customCategoryID` precedent); existing rows migrate to `nil` and survive
    /// untouched. Imported rows carry NO `rawTranscript` (scope guard E).
    var importBatchID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        amount: Decimal,
        currency: Currency,
        context: TransactionContext,
        category: TransactionCategory? = nil,
        customCategoryID: UUID? = nil,
        descriptionText: String,
        merchant: String? = nil,
        date: Date = .now,
        rawTranscript: String? = nil,
        source: TransactionSource,
        importBatchID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.context = context
        self.category = category
        self.customCategoryID = customCategoryID
        self.descriptionText = descriptionText
        self.merchant = merchant
        self.date = date
        self.rawTranscript = rawTranscript
        self.source = source
        self.importBatchID = importBatchID
        self.createdAt = createdAt
    }
}
