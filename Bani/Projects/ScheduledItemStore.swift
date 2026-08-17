import Foundation
import SwiftData

/// The scheduled-money lifecycle seam, kept out of the views so it can be driven
/// directly by tests (no UI, no real notifications). Marking an item done is the
/// card contract's terminal state: it ALWAYS ends in a persisted `Transaction`,
/// linked back via `linkedTransactionID`, with the item flipped to `.done`. Undo
/// deletes that transaction and restores the item to `.pending`.
enum ScheduledItemStore {

    /// Fulfil a scheduled item: create a real `Transaction` from it (edited values
    /// may be supplied by the mark-done card) and link it. Direction maps
    /// incoming → .income, outgoing → .expense. Projects are the business side, so
    /// the created transaction defaults to the Work context.
    @MainActor
    @discardableResult
    static func markDone(
        _ item: ScheduledItem,
        amount: Decimal? = nil,
        currency: Currency? = nil,
        descriptionText: String? = nil,
        context: TransactionContext = .work,
        category: TransactionCategory? = nil,
        date: Date = .now,
        in modelContext: ModelContext
    ) -> Transaction {
        let resolvedDescription = descriptionText ?? (item.title.isEmpty ? item.descriptionText : item.title)
        let transaction = Transaction(
            amount: amount ?? item.amount,
            currency: currency ?? item.currency,
            context: context,
            category: category,
            descriptionText: resolvedDescription,
            date: date,
            source: .manual,
            direction: item.direction.transactionDirection,
            counterparty: item.counterparty,
            projectID: item.projectID
        )
        modelContext.insert(transaction)
        item.status = .done
        item.linkedTransactionID = transaction.id
        try? modelContext.save()
        return transaction
    }

    /// Undo a mark-done: delete the linked transaction (if it still exists) and
    /// restore the item to pending, clearing the link.
    @MainActor
    static func undoDone(_ item: ScheduledItem, in modelContext: ModelContext) {
        if let txID = item.linkedTransactionID {
            let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == txID })
            if let tx = (try? modelContext.fetch(descriptor))?.first {
                modelContext.delete(tx)
            }
        }
        item.status = .pending
        item.linkedTransactionID = nil
        try? modelContext.save()
    }

    /// Delete a scheduled item outright (with any linked transaction left intact —
    /// deleting the plan does not delete a real, already-logged transaction).
    @MainActor
    static func delete(_ item: ScheduledItem, in modelContext: ModelContext) {
        modelContext.delete(item)
        try? modelContext.save()
    }
}
