import Foundation

/// A transaction reduced to what project math needs — a pure value type so all
/// aggregation is unit-testable with no SwiftData (mirrors `SpendItem`). Carries
/// `direction` and `projectID` because project totals split income vs expense and
/// scope by the analytical lens.
struct ProjectTxLine: Equatable, Sendable {
    var amount: Decimal
    var currency: Currency
    var direction: TransactionDirection
    var projectID: UUID?
    var date: Date

    init(amount: Decimal, currency: Currency, direction: TransactionDirection, projectID: UUID?, date: Date = .now) {
        self.amount = amount
        self.currency = currency
        self.direction = direction
        self.projectID = projectID
        self.date = date
    }
}

/// Per-project money totals (all RON-combined at the given rate). Neutral rows
/// (transfers/cash moves) are excluded from every total, exactly like Finances.
struct ProjectTotals: Equatable, Sendable {
    var spent: Decimal      // Σ expenses
    var received: Decimal   // Σ income
    /// Net position: received − spent.
    var net: Decimal { received - spent }
}

/// Pure, `ModelContext`-free project aggregation — the SAME discipline as
/// `FinancesAnalytics`, scoped by `projectID`. Cash is ONE pot; these functions
/// never move money, they only *view* it under a lens. Proven leak-free (no
/// cross-project bleed; Personal/unassigned untouched) in `ProjectScopingTests`.
enum ProjectAnalytics {

    /// RON value of one line; EUR converts via `rate`, or returns the raw amount
    /// when no rate (callers combine only when a rate exists — see the totals
    /// helpers, which pass `rate` through consistently). Mirrors
    /// `FinancesAnalytics.ronValue`.
    static func ronValue(_ line: ProjectTxLine, rate: Decimal?) -> Decimal {
        switch line.currency {
        case .ron: return line.amount
        case .eur: return rate.map { line.amount * $0 } ?? line.amount
        }
    }

    /// Only the lines assigned to `projectID` (the scoping filter). Unassigned
    /// (Personal / `nil`) lines never appear in any project's view.
    static func scoped(_ lines: [ProjectTxLine], to projectID: UUID) -> [ProjectTxLine] {
        lines.filter { $0.projectID == projectID }
    }

    /// Per-project spent/received (RON-combined). With `rate == nil`, EUR lines are
    /// EXCLUDED (no honest combine) — the caller shows the per-currency split.
    static func totals(_ lines: [ProjectTxLine], rate: Decimal?) -> ProjectTotals {
        var spent: Decimal = 0
        var received: Decimal = 0
        for line in lines {
            switch line.direction {
            case .expense:
                spent += combinable(line, rate: rate)
            case .income:
                received += combinable(line, rate: rate)
            case .neutral:
                break // excluded from totals, like Finances
            }
        }
        return ProjectTotals(spent: spent, received: received)
    }

    /// The whole-portfolio net logged position (RON): income − expenses across
    /// EVERYTHING (all lines, every project + Personal), neutral excluded. The
    /// "always-on-top" liquidity anchor.
    static func netLoggedPosition(_ lines: [ProjectTxLine], rate: Decimal?) -> Decimal {
        let t = totals(lines, rate: rate)
        return t.net
    }

    /// Native per-currency totals (NO conversion) for the dashboard currency-split
    /// row: RON vs EUR before any BNR conversion. Expenses + income both count
    /// toward the magnitude shown (neutral excluded).
    static func totalsByCurrency(_ lines: [ProjectTxLine]) -> [Currency: Decimal] {
        var out: [Currency: Decimal] = [:]
        for line in lines where line.direction != .neutral {
            out[line.currency, default: 0] += line.amount
        }
        return out
    }

    /// RON value only when combinable: RON always, EUR only when a rate exists
    /// (never guessed). Used by `totals` so a no-rate EUR line contributes 0 to the
    /// combined figure (the per-currency split still shows it natively).
    private static func combinable(_ line: ProjectTxLine, rate: Decimal?) -> Decimal {
        switch line.currency {
        case .ron: return line.amount
        case .eur: return rate.map { line.amount * $0 } ?? 0
        }
    }
}

// MARK: - Pending scheduled-money rollups (per project)

extension ProjectAnalytics {

    /// A project's pending scheduled money, converted to RON at `rate`. Used by the
    /// project card (expected income total, projected position) and the detail
    /// header. Overdue pending items are included (still a claim / still expected).
    struct PendingRollup: Equatable, Sendable {
        var incoming: Decimal
        var outgoing: Decimal
        var nearestDueDate: Date?
        var hasUnconvertibleCurrency: Bool
        /// Net pending swing (incoming − outgoing).
        var net: Decimal { incoming - outgoing }
    }

    /// Roll up the pending items for one project (pass the project-scoped items).
    static func pendingRollup(_ items: [ScheduledItemSnapshot], rate: Decimal?) -> PendingRollup {
        var incoming: Decimal = 0
        var outgoing: Decimal = 0
        var nearest: Date?
        var unconvertible = false
        for item in items where item.status == .pending {
            if let due = nearest { nearest = min(due, item.dueDate) } else { nearest = item.dueDate }
            guard let ron = LiquidityCalculator.ronValue(of: item.amount, currency: item.currency, rate: rate) else {
                unconvertible = true
                continue
            }
            switch item.direction {
            case .incoming: incoming += ron
            case .outgoing: outgoing += ron
            }
        }
        return PendingRollup(incoming: incoming, outgoing: outgoing,
                             nearestDueDate: nearest, hasUnconvertibleCurrency: unconvertible)
    }
}
