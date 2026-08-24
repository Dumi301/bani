import Foundation

/// Pure date-range math for a `RelativeDateToken` — resolved against an
/// injected reference date + calendar, exactly like `TimeframeRange` (never
/// `Date()`/`Calendar.current` inline), so it is fully unit-testable against a
/// fixed `now`. The model NEVER computes a date itself (see `SearchQueryProposal`
/// docs) — it only classifies the phrase; this resolver does all the arithmetic.
///
/// Meteorological seasons (Northern hemisphere, matching Bucharest): spring =
/// Mar–May, summer = Jun–Aug, fall = Sep–Nov, winter = Dec–Feb (wraps the year
/// boundary). "last X" means the most recently COMPLETED instance of X before
/// `now`: if this year's/cycle's X has already ended, that is "last X"; if `now`
/// falls before or during this cycle's X, "last X" steps back one full cycle —
/// so asking "last spring" while standing inside this year's spring means the
/// spring before it, not the one still in progress.
enum RelativeDateResolver {

    /// The `[start, end)` window `token` refers to, relative to `now`.
    static func resolve(_ token: RelativeDateToken, now: Date, calendar: Calendar) -> DateInterval {
        switch token {
        case .today:
            return calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 0)
        case .yesterday:
            let d = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .day, for: d) ?? DateInterval(start: d, duration: 0)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 0)
        case .lastWeek:
            let d = calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .weekOfYear, for: d) ?? DateInterval(start: d, duration: 0)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 0)
        case .lastMonth:
            let d = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .month, for: d) ?? DateInterval(start: d, duration: 0)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now) ?? DateInterval(start: now, duration: 0)
        case .lastYear:
            let d = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .year, for: d) ?? DateInterval(start: d, duration: 0)
        case .thisSpring:
            return thisSeason(anchorMonth: 3, now: now, calendar: calendar)
        case .lastSpring:
            return lastSeason(anchorMonth: 3, now: now, calendar: calendar)
        case .thisSummer:
            return thisSeason(anchorMonth: 6, now: now, calendar: calendar)
        case .lastSummer:
            return lastSeason(anchorMonth: 6, now: now, calendar: calendar)
        case .thisFall:
            return thisSeason(anchorMonth: 9, now: now, calendar: calendar)
        case .lastFall:
            return lastSeason(anchorMonth: 9, now: now, calendar: calendar)
        case .thisWinter:
            return thisSeason(anchorMonth: 12, now: now, calendar: calendar)
        case .lastWinter:
            return lastSeason(anchorMonth: 12, now: now, calendar: calendar)
        case .january: return namedMonth(1, now: now, calendar: calendar)
        case .february: return namedMonth(2, now: now, calendar: calendar)
        case .march: return namedMonth(3, now: now, calendar: calendar)
        case .april: return namedMonth(4, now: now, calendar: calendar)
        case .may: return namedMonth(5, now: now, calendar: calendar)
        case .june: return namedMonth(6, now: now, calendar: calendar)
        case .july: return namedMonth(7, now: now, calendar: calendar)
        case .august: return namedMonth(8, now: now, calendar: calendar)
        case .september: return namedMonth(9, now: now, calendar: calendar)
        case .october: return namedMonth(10, now: now, calendar: calendar)
        case .november: return namedMonth(11, now: now, calendar: calendar)
        case .december: return namedMonth(12, now: now, calendar: calendar)
        }
    }

    // MARK: - Seasons

    /// A 3-calendar-month season starting `anchorMonth` (3/6/9/12) of `year`.
    private static func seasonRange(anchorMonth: Int, year: Int, calendar: Calendar) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: year, month: anchorMonth, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// The year whose `anchorMonth` season is the one "in effect" for `now`:
    /// for winter (which starts in December) a `now` in January/February belongs
    /// to the winter that started the PREVIOUS December.
    private static func seasonYear(anchorMonth: Int, now: Date, calendar: Calendar) -> Int {
        let comps = calendar.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        guard anchorMonth == 12 else { return year }
        return month <= 2 ? year - 1 : year
    }

    private static func thisSeason(anchorMonth: Int, now: Date, calendar: Calendar) -> DateInterval {
        let year = seasonYear(anchorMonth: anchorMonth, now: now, calendar: calendar)
        return seasonRange(anchorMonth: anchorMonth, year: year, calendar: calendar)
    }

    /// The most recently COMPLETED instance before `now` — steps back one full
    /// year when this cycle's instance has not finished yet (see type docs).
    private static func lastSeason(anchorMonth: Int, now: Date, calendar: Calendar) -> DateInterval {
        let thisYear = seasonYear(anchorMonth: anchorMonth, now: now, calendar: calendar)
        let thisRange = seasonRange(anchorMonth: anchorMonth, year: thisYear, calendar: calendar)
        let year = now >= thisRange.end ? thisYear : thisYear - 1
        return seasonRange(anchorMonth: anchorMonth, year: year, calendar: calendar)
    }

    // MARK: - Named month ("în aprilie" / "in April")

    /// The most recent occurrence of calendar month `monthNumber` (1…12) at or
    /// before `now` — this year if `now`'s month has already reached it, else
    /// last year's occurrence.
    private static func namedMonth(_ monthNumber: Int, now: Date, calendar: Calendar) -> DateInterval {
        let comps = calendar.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 1970
        let nowMonth = comps.month ?? 1
        let targetYear = monthNumber <= nowMonth ? year : year - 1
        let start = calendar.date(from: DateComponents(year: targetYear, month: monthNumber, day: 1)) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }
}
