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

    var label: String {
        switch self {
        case .personal: "Personal"
        case .work: "Work"
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

    var label: String { rawValue.capitalized }
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
enum TransactionSource: String, Codable, CaseIterable, Hashable, Sendable {
    case voice
    case manual
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
    var descriptionText: String
    var merchant: String?
    var date: Date
    var rawTranscript: String?
    var source: TransactionSource
    var createdAt: Date

    init(
        id: UUID = UUID(),
        amount: Decimal,
        currency: Currency,
        context: TransactionContext,
        category: TransactionCategory? = nil,
        descriptionText: String,
        merchant: String? = nil,
        date: Date = .now,
        rawTranscript: String? = nil,
        source: TransactionSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.context = context
        self.category = category
        self.descriptionText = descriptionText
        self.merchant = merchant
        self.date = date
        self.rawTranscript = rawTranscript
        self.source = source
        self.createdAt = createdAt
    }
}
