import Foundation

/// One counterparty's receivables: their pending, incoming scheduled items +
/// RON-scoped total. Pure value type so the People registry's "who owes ME"
/// surface (VISION §2 Position) is unit-tested with no SwiftData.
struct PersonReceivables: Identifiable, Equatable, Sendable {
    var counterparty: String
    /// Sorted soonest-due-first.
    var items: [ScheduledItemSnapshot]
    var total: Decimal

    var id: String { counterparty }
    var count: Int { items.count }

    /// COMPUTED, mirrors `ScheduledItemSnapshot.isOverdue` — never stored.
    func hasOverdue(asOf now: Date = .now) -> Bool {
        items.contains { $0.isOverdue(asOf: now) }
    }
}

/// The grand total + per-person breakdown — the Raport line's data source
/// (P7 reuses this).
struct ReceivablesSummary: Equatable, Sendable {
    var people: [PersonReceivables]
    var grandTotal: Decimal

    static let empty = ReceivablesSummary(people: [], grandTotal: 0)
}

/// Pure grouping/aggregation over PENDING, INCOMING `ScheduledItem`s — "who
/// owes ME" (VISION §2 Position: "Owed people + sum"). Money stays `Decimal`;
/// EUR→RON conversion applies at aggregation time when a `rate` is given (nil
/// → EUR items excluded, matching `PeopleAnalytics.ronValue`).
///
/// Recurring items (P2) mint exactly ONE pending occurrence per series at a
/// time (`ScheduledItemStore.generateNextRecurrenceIfNeeded`'s no-duplicate
/// guard) — so filtering to `status == .pending` alone already counts a
/// recurring receivable once, never once per past/future occurrence.
enum ReceivablesRollup {

    /// L5: `rate` is a `Decimal` (see `RateService.rateDecimal`) so this never
    /// re-derives a `Decimal` from the display `Double` — the source of the FX
    /// display noise this fix removes.
    static func ronValue(_ item: ScheduledItemSnapshot, rate: Decimal?) -> Decimal? {
        switch item.currency {
        case .ron: return item.amount
        case .eur: return rate.map { item.amount * $0 }
        }
    }

    /// Groups pending/incoming items by counterparty (blank counterparties
    /// excluded — there is no "who" to owe). Done items and outgoing items
    /// (money the client owes, not receivables) are excluded entirely.
    static func build(_ items: [ScheduledItemSnapshot], rate: Decimal?) -> ReceivablesSummary {
        var byName: [String: [(item: ScheduledItemSnapshot, ronValue: Decimal)]] = [:]
        var order: [String] = []

        for item in items {
            guard item.status == .pending, item.direction == .incoming else { continue }
            let key = (item.counterparty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let value = ronValue(item, rate: rate) else { continue }
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append((item, value))
        }

        let people: [PersonReceivables] = order.compactMap { name -> PersonReceivables? in
            guard let group = byName[name] else { return nil }
            let total = group.reduce(Decimal(0)) { $0 + $1.ronValue }
            let sortedItems = group.map(\.item).sorted { $0.dueDate < $1.dueDate }
            return PersonReceivables(counterparty: name, items: sortedItems, total: total)
        }.sorted { a, b in
            if a.total != b.total { return a.total > b.total }
            return a.counterparty < b.counterparty
        }

        let grandTotal = people.reduce(Decimal(0)) { $0 + $1.total }
        return ReceivablesSummary(people: people, grandTotal: grandTotal)
    }
}
