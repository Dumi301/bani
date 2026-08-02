import Foundation

/// A transaction reduced to the fields the People view needs — pure value type so
/// the paid/received/net math is unit-tested with no SwiftData.
struct PersonItem: Equatable, Sendable {
    var counterparty: String
    var amount: Decimal
    var currency: Currency
    var direction: TransactionDirection
    var date: Date
}

/// One counterparty's rolled-up totals (B1). `paid` sums the money you sent them
/// (expenses), `received` the money they sent you (income); `net = received −
/// paid`. Neutral rows (transfers/loans) are counted + totalled separately but
/// EXCLUDED from paid/received/net, exactly like the spending/income totals (A3).
struct PersonSummary: Identifiable, Equatable, Sendable {
    var counterparty: String
    var paid: Decimal
    var received: Decimal
    var neutralTotal: Decimal
    var neutralCount: Int
    var count: Int

    var id: String { counterparty }
    var net: Decimal { received - paid }
    var hasNeutral: Bool { neutralCount > 0 }
}

/// Direction-aware per-counterparty aggregation (B). Money stays `Decimal`;
/// EUR→RON conversion applies at aggregation time when a `rate` is given (nil →
/// EUR excluded, matching the rest of Finances).
enum PeopleAnalytics {

    static func ronValue(_ item: PersonItem, rate: Double?) -> Decimal? {
        switch item.currency {
        case .ron: return item.amount
        case .eur: return rate.map { item.amount * Decimal($0) }
        }
    }

    /// Per-counterparty summaries, sorted by absolute net descending (the people
    /// you have the most outstanding with float to the top).
    static func summaries(_ items: [PersonItem], rate: Double?) -> [PersonSummary] {
        var byName: [String: PersonSummary] = [:]
        for item in items {
            let key = item.counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let value = ronValue(item, rate: rate) else { continue }
            var s = byName[key] ?? PersonSummary(counterparty: key, paid: 0, received: 0, neutralTotal: 0, neutralCount: 0, count: 0)
            switch item.direction {
            case .expense: s.paid += value
            case .income: s.received += value
            case .neutral: s.neutralTotal += value; s.neutralCount += 1
            }
            s.count += 1
            byName[key] = s
        }
        return byName.values.sorted { a, b in
            let na = abs(a.net), nb = abs(b.net)
            if na != nb { return na > nb }
            return a.counterparty < b.counterparty
        }
    }

    /// A per-person chronological running balance (B1): income adds, expense
    /// subtracts, neutral rows do not move it (their in/out isn't modelled).
    struct BalancePoint: Identifiable, Equatable, Sendable {
        var date: Date
        var balance: Decimal
        var id: Double { date.timeIntervalSince1970 }
    }

    static func runningBalance(_ items: [PersonItem], rate: Double?) -> [BalancePoint] {
        let sorted = items.sorted { $0.date < $1.date }
        var running = Decimal(0)
        var out: [BalancePoint] = []
        for item in sorted {
            guard let value = ronValue(item, rate: rate) else { continue }
            switch item.direction {
            case .income: running += value
            case .expense: running -= value
            case .neutral: break
            }
            out.append(BalancePoint(date: item.date, balance: running))
        }
        return out
    }
}
