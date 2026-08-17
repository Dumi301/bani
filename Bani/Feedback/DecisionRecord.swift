import Foundation
import SwiftData

/// How a confirmation card was ultimately resolved. Exactly one of these is
/// written to the ledger per card resolution (B1) — the app's memory of being
/// right or wrong.
enum DecisionOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    /// 👍 — the user explicitly confirmed the guess.
    case confirmedExplicit
    /// The countdown expired with no correction (implicit yes).
    case confirmedImplicit
    /// 👎 then an edited save — the guess was wrong in one or more fields.
    case corrected
    /// 👎 then a discard — likely a hallucination; kept as a refiner-quality datapoint.
    case discarded

    /// Whether this outcome counts as a confirmation (hit) for trust scoring.
    /// `corrected` is a miss; `discarded` is excluded from a rule's trust window
    /// entirely (it is not a signal about the CATEGORY guess).
    var trustSample: Bool? {
        switch self {
        case .confirmedExplicit, .confirmedImplicit: return true
        case .corrected: return false
        case .discarded: return nil
        }
    }
}

/// Which fields the user changed when they corrected a card. An `OptionSet` so a
/// single record captures every changed field; surfaced in diagnostics (B5) as
/// parser/categorizer accuracy signal.
struct CorrectedFields: OptionSet, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let amount      = CorrectedFields(rawValue: 1 << 0)
    static let currency    = CorrectedFields(rawValue: 1 << 1)
    static let description = CorrectedFields(rawValue: 1 << 2)
    static let category    = CorrectedFields(rawValue: 1 << 3)
    static let context     = CorrectedFields(rawValue: 1 << 4)
    static let date        = CorrectedFields(rawValue: 1 << 5)
    /// v1.2a — the project chip was changed from the smart-default (last-used
    /// project). Additive bit; `correctedFieldsRaw` is a plain stored `Int`, so
    /// this widens the set with no migration surface.
    static let project     = CorrectedFields(rawValue: 1 << 6)
}

/// The feedback ledger's one row per card resolution (B1). A NEW, separate
/// SwiftData entity — the frozen `Transaction` model is untouched. Accumulated
/// records drive the trust engine (B4) and the diagnostics screen (B5).
///
/// `outcome` and `correctedFields` are stored in raw (predicate-friendly) form
/// with typed computed accessors, matching the store's in-memory filtering style.
@Model
final class DecisionRecord {
    var id: UUID
    var createdAt: Date
    /// The saved transaction this decision produced (`nil` for a discard).
    var transactionID: UUID?
    var guessedCategory: TransactionCategory?
    var guessedContext: TransactionContext
    /// The category rule that fired for the guess (`nil` when no rule matched →
    /// the guess was `.other`). Trust is scored per fired rule.
    var firedRuleID: UUID?
    /// The refined transcript the guess was made from (A1 `cleanText`); empty for
    /// manual or amount-less flows.
    var refinedText: String
    /// Stored natively (String-raw Codable enum, like `CategoryRuleOrigin`).
    var outcome: DecisionOutcome
    /// `CorrectedFields` stored as its raw `Int` (predicate-friendly) with a typed
    /// computed accessor.
    var correctedFieldsRaw: Int
    var latencySeconds: Double

    var correctedFields: CorrectedFields {
        get { CorrectedFields(rawValue: correctedFieldsRaw) }
        set { correctedFieldsRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        transactionID: UUID? = nil,
        guessedCategory: TransactionCategory?,
        guessedContext: TransactionContext,
        firedRuleID: UUID? = nil,
        refinedText: String = "",
        outcome: DecisionOutcome,
        correctedFields: CorrectedFields = [],
        latencySeconds: Double = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transactionID = transactionID
        self.guessedCategory = guessedCategory
        self.guessedContext = guessedContext
        self.firedRuleID = firedRuleID
        self.refinedText = refinedText
        self.outcome = outcome
        self.correctedFieldsRaw = correctedFields.rawValue
        self.latencySeconds = latencySeconds
    }
}
