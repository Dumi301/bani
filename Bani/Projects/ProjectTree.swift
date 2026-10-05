import Foundation

// MARK: - Cost buckets

/// v0.4 — what a project cost *is*, for the "acquisition + costs vs earnings"
/// card. Derived from the seeded custom category by the caller (the view owns
/// the id → seeded lookup); the engine only sums. Labor vs materials is the
/// client's own split (manoperă paid cash to workers, materiale billed by
/// suppliers) — it rides on the existing category axis, no new column.
enum CostBucket: String, Codable, Hashable, Sendable, CaseIterable {
    case acquisition
    case labor
    case materials
    case other

    init(seeded: SeededCustomCategory?) {
        switch seeded {
        case .achizitie: self = .acquisition
        case .manopera, .platiPersoane: self = .labor
        case .materialeConstructii, .amenajareMobilier: self = .materials
        default: self = .other
        }
    }
}

/// Where a project sits on the home screen. Derived, never stored.
enum ProjectBucket: String, Hashable, Sendable, CaseIterable {
    /// `.prospect` — not bought yet; carries the planned contract schedule.
    case planned
    /// Active with costs running and (usually) an expected sale.
    case building
    /// Active, recurring income, no expected sale — a held/rented property.
    case renting
    case finished
}

// MARK: - Rollup

/// Everything the project card and node detail show for ONE node, summed over
/// the node AND its descendants (a lot = Σ its houses + lot-level lines). RON
/// at the given rate; EUR lines without a rate are excluded, exactly like
/// `ProjectAnalytics.totals`.
struct ProjectRollup: Equatable, Sendable, Identifiable {
    var projectID: UUID
    var bucket: ProjectBucket
    var acquisition: Decimal = 0
    var labor: Decimal = 0
    var materials: Decimal = 0
    var otherCosts: Decimal = 0
    /// Σ income lines (sales, rent received, anything incoming) on the subtree.
    var earnings: Decimal = 0
    /// Pending outgoing, non-loan scheduled payments on the subtree ("still due").
    var pendingOut: Decimal = 0
    /// Pending incoming scheduled money on the subtree.
    var pendingIn: Decimal = 0
    /// Monthly-equivalent of the subtree's recurring incoming schedules (rent).
    var monthlyRecurringIncome: Decimal = 0
    /// The node's own expected sale, else Σ of its children's when any is set.
    var expectedSalePrice: Decimal?
    var expectedSaleDate: Date?
    var firstDate: Date?
    var lastDate: Date?
    var childCount: Int = 0

    var id: UUID { projectID }
    /// Build/renovation costs — everything except the purchase itself.
    var costs: Decimal { labor + materials + otherCosts }
    /// Capital deployed = acquisition + costs.
    var invested: Decimal { acquisition + costs }
    /// What has actually come back minus what actually went out.
    var realizedProfit: Decimal { earnings - invested }
    /// If the expected sale lands: sale + earnings so far − invested − still due.
    var expectedProfit: Decimal? { expectedSalePrice.map { $0 + earnings - invested - pendingOut } }
    /// Labor / materials share of `costs`, 0…100 (0 when there are no costs).
    var laborPercent: Decimal { percent(labor, of: costs) }
    var materialsPercent: Decimal { percent(materials, of: costs) }

    private func percent(_ part: Decimal, of whole: Decimal) -> Decimal {
        whole > 0 ? AmortizationSchedule.rounded2(part / whole * 100) : 0
    }
}

// MARK: - Tree

/// Pure, `ModelContext`-free project-tree math — the same discipline as
/// `ProjectAnalytics` / `LiquidityCalculator`. A child is a `Project` whose
/// `parentProjectID` points at its parent (id pointer, never a relationship),
/// so every existing `projectID` on Transaction / ScheduledItem / Loan already
/// scopes to a house; the tree only decides which ids roll up where.
enum ProjectTree {

    /// Top-level nodes: no parent, OR a parent that no longer exists (an
    /// orphan surfaces as a root rather than disappearing). Sorted like the
    /// grid: `sortOrder`, then name.
    static func roots(_ projects: [ProjectSnapshot]) -> [ProjectSnapshot] {
        let ids = Set(projects.map(\.id))
        return sorted(projects.filter { $0.parentProjectID.map { !ids.contains($0) } ?? true })
    }

    /// Direct children of `parentID`, sorted.
    static func children(of parentID: UUID, in projects: [ProjectSnapshot]) -> [ProjectSnapshot] {
        sorted(projects.filter { $0.parentProjectID == parentID })
    }

    /// `id` plus every descendant, cycle-safe (a malformed A→B→A loop
    /// terminates and yields {A, B}).
    static func descendantIDs(of id: UUID, in projects: [ProjectSnapshot]) -> Set<UUID> {
        var out: Set<UUID> = [id]
        var frontier = [id]
        while let current = frontier.popLast() {
            for child in projects where child.parentProjectID == current {
                if out.insert(child.id).inserted { frontier.append(child.id) }
            }
        }
        return out
    }

    /// The root this node belongs to (itself when top-level); cycle-safe.
    static func rootID(of id: UUID, in projects: [ProjectSnapshot]) -> UUID {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var current = id
        var seen: Set<UUID> = [id]
        while let parent = byID[current]?.parentProjectID, byID[parent] != nil, seen.insert(parent).inserted {
            current = parent
        }
        return current
    }

    /// One node's rollup over its subtree.
    static func rollup(
        _ id: UUID,
        projects: [ProjectSnapshot],
        lines: [ProjectTxLine],
        items: [ScheduledItemSnapshot],
        rate: Decimal?
    ) -> ProjectRollup {
        let node = projects.first { $0.id == id }
        let ids = descendantIDs(of: id, in: projects)
        let kids = children(of: id, in: projects)
        func inTree(_ projectID: UUID?) -> Bool { projectID.map { ids.contains($0) } ?? false }

        var r = ProjectRollup(projectID: id, bucket: .building)
        r.childCount = kids.count

        for line in lines where inTree(line.projectID) {
            r.firstDate = r.firstDate.map { min($0, line.date) } ?? line.date
            r.lastDate = r.lastDate.map { max($0, line.date) } ?? line.date
            guard let ron = LiquidityCalculator.ronValue(of: line.amount, currency: line.currency, rate: rate) else { continue }
            switch line.direction {
            case .income: r.earnings += ron
            case .neutral: break
            case .expense:
                switch line.bucket {
                case .acquisition: r.acquisition += ron
                case .labor: r.labor += ron
                case .materials: r.materials += ron
                case .other: r.otherCosts += ron
                }
            }
        }

        for item in items where item.status == .pending && item.loanID == nil && inTree(item.projectID) {
            guard let ron = LiquidityCalculator.ronValue(of: item.amount, currency: item.currency, rate: rate) else { continue }
            switch item.direction {
            case .outgoing: r.pendingOut += ron
            case .incoming: r.pendingIn += ron
            }
        }
        r.monthlyRecurringIncome = RecurringIncome.monthlyTotal(
            items: items.filter { inTree($0.projectID) }, rate: rate
        )

        if let own = node?.expectedSalePrice {
            r.expectedSalePrice = own
            r.expectedSaleDate = node?.expectedSaleDate
        } else {
            let priced = kids.compactMap(\.expectedSalePrice)
            if !priced.isEmpty {
                r.expectedSalePrice = priced.reduce(0, +)
                r.expectedSaleDate = kids.compactMap(\.expectedSaleDate).max()
            }
        }

        switch node?.status {
        case .prospect: r.bucket = .planned
        case .finished: r.bucket = .finished
        default: r.bucket = (r.monthlyRecurringIncome > 0 && r.expectedSalePrice == nil) ? .renting : .building
        }
        return r
    }

    /// Rollups for every root, in root order.
    static func rootRollups(
        projects: [ProjectSnapshot],
        lines: [ProjectTxLine],
        items: [ScheduledItemSnapshot],
        rate: Decimal?
    ) -> [ProjectRollup] {
        roots(projects).map { rollup($0.id, projects: projects, lines: lines, items: items, rate: rate) }
    }

    private static func sorted(_ projects: [ProjectSnapshot]) -> [ProjectSnapshot] {
        projects.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Recurring income

/// One recurring incoming series as the home screen lists it: a salary (no
/// project) or a rent (project = the property). Grouped by `seriesID` so a
/// marked-done occurrence and its pending successor read as ONE source.
struct RecurringIncomeSource: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var counterparty: String?
    var projectID: UUID?
    var recurrence: RecurrenceRule
    /// RON per occurrence (latest item in the series).
    var amount: Decimal
    /// Earliest pending due date in the series.
    var nextDueDate: Date?
    /// Σ RON of the series' occurrences due in the asked month (any status).
    var expectedThisMonth: Decimal
    /// Σ RON of those occurrences already marked done.
    var receivedThisMonth: Decimal
    /// Salary / passive income = no property behind it.
    var isSalary: Bool { projectID == nil }
}

enum RecurringIncome {

    /// Per-occurrence amount scaled to one month.
    static func monthlyEquivalent(_ amount: Decimal, _ rule: RecurrenceRule) -> Decimal {
        switch rule {
        case .none: return 0
        case .weekly: return amount * 52 / 12
        case .monthly: return amount
        case .quarterly: return amount / 3
        case .yearly: return amount / 12
        }
    }

    /// Monthly-equivalent total of the pending recurring incoming series in `items`
    /// (one per series; loan items excluded).
    static func monthlyTotal(items: [ScheduledItemSnapshot], rate: Decimal?) -> Decimal {
        var seen = Set<UUID>()
        var total: Decimal = 0
        for item in items where item.direction == .incoming && item.status == .pending
            && item.recurrence != .none && item.loanID == nil {
            guard seen.insert(item.seriesID ?? item.id).inserted,
                  let ron = LiquidityCalculator.ronValue(of: item.amount, currency: item.currency, rate: rate)
            else { continue }
            total += monthlyEquivalent(ron, item.recurrence)
        }
        return total
    }

    /// Every recurring incoming series, salaries first then by title, with this
    /// month's expected / received figures. `month` is any instant in the month.
    static func sources(
        items: [ScheduledItemSnapshot],
        month: Date,
        calendar: Calendar,
        rate: Decimal?
    ) -> [RecurringIncomeSource] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let recurring = items.filter {
            $0.direction == .incoming && $0.loanID == nil && ($0.recurrence != .none || $0.seriesID != nil)
        }
        let groups = Dictionary(grouping: recurring) { $0.seriesID ?? $0.id }

        var out: [RecurringIncomeSource] = []
        for (key, series) in groups {
            let latest = series.max { $0.dueDate < $1.dueDate }!
            let amount = LiquidityCalculator.ronValue(of: latest.amount, currency: latest.currency, rate: rate) ?? 0
            var expected: Decimal = 0
            var received: Decimal = 0
            for item in series where interval.contains(item.dueDate) {
                let ron = LiquidityCalculator.ronValue(of: item.amount, currency: item.currency, rate: rate) ?? 0
                expected += ron
                if item.status == .done { received += ron }
            }
            out.append(RecurringIncomeSource(
                id: key,
                title: latest.title,
                counterparty: latest.counterparty,
                projectID: latest.projectID,
                recurrence: latest.recurrence,
                amount: amount,
                nextDueDate: series.filter { $0.status == .pending }.map(\.dueDate).min(),
                expectedThisMonth: expected,
                receivedThisMonth: received
            ))
        }
        return out.sorted {
            if $0.isSalary != $1.isSalary { return $0.isSalary }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
