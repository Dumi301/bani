import Foundation

/// The analytics timeframe the Finances tab is scoped to (D1). Remembered across
/// launches via `@AppStorage("financesTimeframe")` (owned by `FinancesView`); a
/// custom range persists its start/end separately as primitives.
enum TimeframePreset: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case sixMonths
    case year
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .sixMonths: "6M"
        case .year: "Year"
        case .custom: "Custom"
        }
    }

    /// Bars are daily for short windows, monthly for long ones (D1b).
    var bucketUnit: Calendar.Component {
        switch self {
        case .week, .month, .custom: .day
        case .sixMonths, .year: .month
        }
    }
}

/// Pure date-range math for a `TimeframePreset` — resolved against a reference
/// date and calendar so it is fully unit-testable (no `.now`, no `Calendar.current`).
///
/// Calendar-based on purpose: `month`'s previous period is the previous CALENDAR
/// month, so short-month edges (Feb ← Mar) align correctly (D4).
enum TimeframeRange {

    /// The current window `[start, end)` for `preset`.
    static func current(_ preset: TimeframePreset, reference: Date, calendar: Calendar, custom: DateInterval? = nil) -> DateInterval {
        switch preset {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: reference) ?? DateInterval(start: reference, duration: 0)
        case .month:
            return calendar.dateInterval(of: .month, for: reference) ?? DateInterval(start: reference, duration: 0)
        case .year:
            return calendar.dateInterval(of: .year, for: reference) ?? DateInterval(start: reference, duration: 0)
        case .sixMonths:
            // The current month plus the five preceding months.
            let thisMonth = calendar.dateInterval(of: .month, for: reference) ?? DateInterval(start: reference, duration: 0)
            let start = calendar.date(byAdding: .month, value: -5, to: thisMonth.start) ?? thisMonth.start
            return DateInterval(start: start, end: thisMonth.end)
        case .custom:
            return custom ?? (calendar.dateInterval(of: .month, for: reference) ?? DateInterval(start: reference, duration: 0))
        }
    }

    /// The immediately-preceding equivalent window, ending exactly at
    /// `current.start` (the Revolut comparison baseline, D1c).
    static func previous(_ preset: TimeframePreset, current: DateInterval, calendar: Calendar) -> DateInterval {
        let start: Date
        switch preset {
        case .week:
            start = calendar.date(byAdding: .weekOfYear, value: -1, to: current.start) ?? current.start
        case .month:
            start = calendar.date(byAdding: .month, value: -1, to: current.start) ?? current.start
        case .sixMonths:
            start = calendar.date(byAdding: .month, value: -6, to: current.start) ?? current.start
        case .year:
            start = calendar.date(byAdding: .year, value: -1, to: current.start) ?? current.start
        case .custom:
            // No calendar unit for a free range — mirror its exact duration.
            return DateInterval(start: current.start.addingTimeInterval(-current.duration), end: current.start)
        }
        return DateInterval(start: start, end: current.start)
    }
}
