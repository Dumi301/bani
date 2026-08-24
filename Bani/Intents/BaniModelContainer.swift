import Foundation
import SwiftData

/// The ONE on-disk `ModelContainer`, shared by the app (normal foreground launch)
/// and the `LogPaymentIntent` background launch.
///
/// Why a shared singleton: when Shortcuts runs `LogPaymentIntent` with
/// `openAppWhenRun == false`, iOS spins up the app process in the background —
/// `BaniApp.init()` runs and creates the container, then the intent's `perform()`
/// runs and needs to write to the SAME store. Two separate `ModelContainer`
/// instances over one on-disk file in one process is unsafe, so the app's on-disk
/// path AND the intent both resolve to `shared`. Whichever touches the lazy
/// `static let` first creates it; the other reuses it (Swift `static let` is
/// thread-safe), so there is always exactly one container for the default store.
///
/// The store URL is the SwiftData default (`Application Support/default.store`) —
/// unchanged from the pre-run app, so existing users' data is preserved. The
/// share-extension handoff (Part B) uses a plain App-Group file directory, NOT the
/// SwiftData store, so the store is never relocated and there is no migration.
enum BaniModelContainer {

    /// The full app model set — identical to the schema `BaniApp` used before this
    /// run, so the default store URL and on-disk layout are byte-for-byte the same.
    static let schema = Schema([
        Transaction.self, CategoryRule.self,
        DecisionRecord.self, ContextRule.self, CorrectionMemory.self,
        CustomCategory.self, ImportBatch.self,
        // v1.2a "Projects Core": two new entities + Transaction.projectID. All
        // additive → lightweight migration, existing default.store preserved
        // (proven in ProjectMigrationTests).
        Project.self,
        // v1.3 "People registry": one new entity, zero field additions on any
        // existing entity — Transaction/ScheduledItem.counterparty stay plain
        // strings, matched by normalized name only (never an FK). Lightweight
        // migration, existing default.store preserved (proven in
        // PersonMigrationTests).
        Person.self, ScheduledItem.self,
        // v2 "Balance anchoring / reconciliation": one new entity (BalanceAnchor).
        // Additive → lightweight migration, existing default.store preserved
        // (proven in BalanceAnchorMigrationTests). Registered AFTER ScheduledItem.self.
        BalanceAnchor.self,
        // v1.2b "Loans + rate-splits": one new entity + additive Transaction.loanID
        // / ScheduledItem.loanID (both optional → lightweight migration, existing
        // default.store preserved, proven in LoanMigrationTests).
        Loan.self,
        // v2 P9 "Open banking / GoCardless": one new entity (BankLink) holding ONLY
        // non-secret link metadata — secrets live in the Keychain, never the store.
        // Additive → lightweight migration, existing default.store preserved
        // (proven in the BankLink-carrying in-memory container used by BankLinkStore
        // / BankSync tests). Registered AFTER Loan.self (the additive tail, itself
        // after BalanceAnchor.self).
        BankLink.self,
    ])

    static func make(inMemory: Bool) throws -> ModelContainer {
        // The SAME configuration form the app shipped before this run
        // (`isStoredInMemoryOnly` only, no explicit URL) → the identical default
        // store URL, so existing users' data is preserved.
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// The single on-disk container. `try!` mirrors `BaniApp`'s prior
    /// `fatalError` on container-creation failure (an unrecoverable launch state).
    static let shared: ModelContainer = {
        do { return try make(inMemory: false) }
        catch { fatalError("Failed to create shared ModelContainer: \(error)") }
    }()
}
