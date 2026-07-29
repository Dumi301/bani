import Foundation

/// A transaction reduced to the fields analytics needs — a pure value type so
/// all aggregation is unit-testable with no SwiftData. Carries BOTH the preset
/// enum and the optional custom id (C3); `categoryRef` unifies them for grouping.
struct SpendItem: Equatable, Sendable {
    var amount: Decimal
    var currency: Currency
    var category: TransactionCategory?
    var customCategoryID: UUID?
    var date: Date

    init(amount: Decimal, currency: Currency, category: TransactionCategory? = nil, customCategoryID: UUID? = nil, date: Date) {
        self.amount = amount
        self.currency = currency
        self.category = category
        self.customCategoryID = customCategoryID
        self.date = date
    }

    /// The unified category identity used for chart/breakdown grouping.
    var categoryRef: CategoryRef? {
        if let customCategoryID { return .custom(customCategoryID) }
        if let category { return .preset(category) }
        return nil
    }
}

/// All Finances-tab aggregation (D3). Money stays `Decimal` throughout; EUR→RON
/// conversion is applied at aggregation time ONLY when a display `rate` is
/// provided (the caller passes `nil` to trigger the per-currency fallback).
enum FinancesAnalytics {

    // MARK: - RON conversion (display-time, Decimal)

    /// The RON-equivalent of one item. `.ron` passes through; `.eur` converts
    /// with `rate` when present, otherwise returns the raw EUR amount (the caller
    /// only combines when a rate exists — see `combinedTotal`).
    static func ronValue(_ item: SpendItem, rate: Double?) -> Decimal {
        switch item.currency {
        case .ron: return item.amount
        case .eur: return rate.map { item.amount * Decimal($0) } ?? item.amount
        }
    }

    // MARK: - Filtering

    /// Items whose date falls in `[interval.start, interval.end)`.
    static func items(_ items: [SpendItem], in interval: DateInterval) -> [SpendItem] {
        items.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    // MARK: - Totals

    /// RON-combined total over the items. With `rate == nil`, EUR items are
    /// EXCLUDED (there is no honest way to combine them) — the caller shows the
    /// side-by-side per-currency fallback instead.
    static func combinedTotal(_ items: [SpendItem], rate: Double?) -> Decimal {
        items.reduce(Decimal(0)) { sum, item in
            switch item.currency {
            case .ron: return sum + item.amount
            case .eur: return rate.map { sum + item.amount * Decimal($0) } ?? sum
            }
        }
    }

    /// Raw per-currency totals (no conversion) — the no-rate fallback + the
    /// per-currency breakdown line.
    static func totalsByCurrency(_ items: [SpendItem]) -> [Currency: Decimal] {
        var out: [Currency: Decimal] = [:]
        for item in items { out[item.currency, default: 0] += item.amount }
        return out
    }

    // MARK: - Category breakdown

    struct CategoryTotal: Equatable, Identifiable, Sendable {
        var categoryRef: CategoryRef?
        var total: Decimal
        var count: Int
        var id: String { CategoryRef.sortKey(categoryRef) }
        /// Back-compat accessor: the preset value when this total is a preset.
        var category: TransactionCategory? { categoryRef?.presetValue }
    }

    /// Per-category totals (RON-combined when `rate` given, else the passed items
    /// should already be single-currency), sorted by total descending. Custom
    /// categories aggregate as their own `CategoryRef.custom` buckets (C3).
    static func byCategory(_ items: [SpendItem], rate: Double?) -> [CategoryTotal] {
        var totals: [CategoryRef?: (total: Decimal, count: Int)] = [:]
        for item in items {
            let value = ronValue(item, rate: rate)
            var entry = totals[item.categoryRef] ?? (0, 0)
            entry.total += value
            entry.count += 1
            totals[item.categoryRef] = entry
        }
        return totals
            .map { CategoryTotal(categoryRef: $0.key, total: $0.value.total, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.total != rhs.total { return lhs.total > rhs.total }
                return CategoryRef.sortKey(lhs.categoryRef) < CategoryRef.sortKey(rhs.categoryRef)
            }
    }

    /// A category total as a fraction (0…1) of the period total. Zero when the
    /// period total is zero (never a divide-by-zero).
    static func fraction(of categoryTotal: Decimal, periodTotal: Decimal) -> Double {
        guard periodTotal > 0 else { return 0 }
        return NSDecimalNumber(decimal: categoryTotal).doubleValue
            / NSDecimalNumber(decimal: periodTotal).doubleValue
    }

    // MARK: - Time buckets (bars)

    struct TimeBucket: Equatable, Identifiable, Sendable {
        var start: Date
        var total: Decimal
        var id: Date { start }
    }

    /// Sums items into `unit`-aligned buckets across `interval`, filling empty
    /// buckets with zero so the bar chart never shows a gap (D2 empty states).
    static func buckets(_ items: [SpendItem], interval: DateInterval, unit: Calendar.Component, calendar: Calendar, rate: Double?) -> [TimeBucket] {
        var sums: [Date: Decimal] = [:]
        for item in items {
            let start = calendar.dateInterval(of: unit, for: item.date)?.start ?? item.date
            sums[start, default: 0] += ronValue(item, rate: rate)
        }

        var buckets: [TimeBucket] = []
        var cursor = calendar.dateInterval(of: unit, for: interval.start)?.start ?? interval.start
        // Guard the loop so a degenerate interval can never spin forever.
        var guardCount = 0
        while cursor < interval.end && guardCount < 400 {
            buckets.append(TimeBucket(start: cursor, total: sums[cursor] ?? 0))
            cursor = calendar.date(byAdding: unit, value: 1, to: cursor) ?? interval.end
            guardCount += 1
        }
        return buckets
    }

    /// The half-open date range `[start, start + 1 unit)` a bar bucket covers —
    /// the exact filter applied to the transaction list when a bar is tapped
    /// (A3). Calendar-based so month-length edges (28/30/31 days) are correct (A4).
    static func bucketRange(start: Date, unit: Calendar.Component, calendar: Calendar) -> DateInterval {
        let end = calendar.date(byAdding: unit, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Mean bucket total — the "average" line overlaid on the bars (D1b).
    static func average(_ buckets: [TimeBucket]) -> Decimal {
        guard !buckets.isEmpty else { return 0 }
        let total = buckets.reduce(Decimal(0)) { $0 + $1.total }
        return total / Decimal(buckets.count)
    }

    // MARK: - Cumulative trend (line, current vs previous)

    struct CumulativePoint: Equatable, Identifiable, Sendable {
        var date: Date
        var cumulative: Decimal
        /// Display date on the CURRENT window's x-axis (previous-period points are
        /// shifted forward by the window length so the two lines overlay).
        var alignedDate: Date
        var isPrevious: Bool
        var id: String { "\(isPrevious ? "p" : "c")-\(date.timeIntervalSince1970)" }
    }

    /// A running-sum series for one window. `displayShift` maps a previous-period
    /// point onto the current window (0 for the current period).
    static func cumulative(_ items: [SpendItem], rate: Double?, isPrevious: Bool, displayShift: TimeInterval) -> [CumulativePoint] {
        let sorted = items.sorted { $0.date < $1.date }
        var running = Decimal(0)
        return sorted.map { item in
            running += ronValue(item, rate: rate)
            return CumulativePoint(
                date: item.date,
                cumulative: running,
                alignedDate: item.date.addingTimeInterval(displayShift),
                isPrevious: isPrevious
            )
        }
    }
}

extension Decimal {
    /// Display-only bridge to `Double` for Swift Charts plotting (charts require
    /// `Plottable`, which `Decimal` is not). Aggregation always stays `Decimal`;
    /// only the plotted values cross this boundary.
    var chartDouble: Double { NSDecimalNumber(decimal: self).doubleValue }
}
