import Foundation

/// v0.3 — which pot a transaction moved: the bank account or cash on hand.
/// Stored as an optional raw string on `Transaction` (`paymentMethodRaw`) so
/// the frozen seam stays additive; `nil` = unknown, counted as bank everywhere.
enum PaymentMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case bank
    case cash

    var label: String {
        switch self {
        case .bank: String(localized: "payment.bank")
        case .cash: String(localized: "payment.cash")
        }
    }
}

/// Deterministic, offline guess of the pot from what the row already carries.
/// Runs inside `Transaction.init` whenever no explicit method is passed, so
/// every creation site (voice, manual, import, auto-log, bank sync, restore)
/// gets it for free and an explicit UI choice always wins.
/// ponytail: keyword rule only — add a merchant→method memory (like
/// `CategoryRule`) once the client is seen correcting the same vendor twice.
enum PaymentMethodInference {
    static let cashKeywords = ["numerar", "cash", "bani gheata", "din mana", "gheata"]
    static let bankKeywords = ["card", "pos", "transfer", "apple pay", "revolut", "op ", "ordin de plata", "virament"]

    static func infer(source: TransactionSource, text: String) -> PaymentMethod? {
        // Apple Pay capture, shared bank notifications and Enable Banking rows all
        // come from an account by construction.
        if source == .autoLogged { return .bank }
        let t = " " + Categorizer.normalize(text) + " "
        if cashKeywords.contains(where: { t.contains($0) }) { return .cash }
        if bankKeywords.contains(where: { t.contains($0) }) { return .bank }
        // Spreadsheet/document rows are bank statements unless they say cash.
        return source == .imported ? .bank : nil
    }
}
