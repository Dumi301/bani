import Foundation

/// The smart-default rule for assigning a project at entry, extracted so it is
/// unit-testable independent of any view. Work entries pre-fill the last-used
/// project; Personal entries are never project-tagged (projects are the business
/// side — Personal transactions live exactly as before).
enum ProjectAssignment {

    /// The project a new entry should default to.
    /// - `context == .work` → the last-used project (parsed from its persisted
    ///   UUID string), or `nil` if none/invalid.
    /// - `context == .personal` → always `nil` (no chip, no assignment).
    static func smartDefault(context: TransactionContext, lastUsedRaw: String) -> UUID? {
        guard context == .work else { return nil }
        return UUID(uuidString: lastUsedRaw)
    }

    /// v0.4 — the labor default: a Work entry that names a person and whose
    /// description matched no category rule is, for this client, a cash payment
    /// to a worker (manoperă). Materials and anything with a matching keyword
    /// keep their rule; Personal never gets it.
    static func laborDefault(context: TransactionContext, counterparty: String, ruleMatched: Bool) -> Bool {
        context == .work && !ruleMatched
            && !counterparty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
