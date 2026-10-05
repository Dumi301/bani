import Foundation
import SwiftData

// MARK: - SyncStamped

/// v0.4 — sync prep for the v0.5 shared vault. Every user-data entity carries
/// an optional `updatedAt` (nil = legacy row, read as `createdAt`). Rather than
/// touching the ~25 call sites that insert or mutate models, ONE
/// `ModelContext.willSave` observer stamps every inserted/changed row just
/// before the context writes it. The merge rule later is last-write-wins on
/// this column, so correctness depends on it being set everywhere — hence one
/// hook, not many edits.
protocol SyncStamped: AnyObject {
    func stampUpdated(_ now: Date)
}

// MARK: - SyncStamp

@MainActor
final class SyncStamp: NSObject {
    static let shared = SyncStamp()
    private var installed = Set<ObjectIdentifier>()

    /// Idempotent per context. The app installs on its main context at launch;
    /// tests install on their in-memory context.
    func install(on context: ModelContext) {
        guard installed.insert(ObjectIdentifier(context)).inserted else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(willSave(_:)),
            name: ModelContext.willSave, object: context
        )
    }

    /// Posted synchronously on the saving context's thread — the main actor for
    /// every context we install on — so the hop below is an assertion, not a
    /// dispatch.
    @objc nonisolated private func willSave(_ note: Notification) {
        guard let context = note.object as? ModelContext else { return }
        MainActor.assumeIsolated { Self.stamp(context) }
    }

    /// Stamps every pending insert/change in `context`. Exposed so tests can
    /// drive it without a real save.
    static func stamp(_ context: ModelContext) {
        let now = Date.now
        for model in context.insertedModelsArray { (model as? SyncStamped)?.stampUpdated(now) }
        for model in context.changedModelsArray { (model as? SyncStamped)?.stampUpdated(now) }
    }
}

// MARK: - Conformances (the ten user-data entities with the new column)
// `CategoryRule` / `ContextRule` / `CorrectionMemory` already own a semantic
// `updatedAt` maintained by their stores — left alone on purpose.

extension Transaction: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension Project: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension Person: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension ScheduledItem: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension BalanceAnchor: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension Loan: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension BankLink: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension CustomCategory: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension ImportBatch: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
extension DecisionRecord: SyncStamped { func stampUpdated(_ now: Date) { updatedAt = now } }
