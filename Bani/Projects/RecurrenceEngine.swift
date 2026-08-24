import Foundation

/// Pure recurrence math for `ScheduledItem` - no `ModelContext`, no side effects,
/// so every rule is fully unit-testable (`RecurrenceEngineTests`). Calendar-based
/// throughout (`.day` / `.month` / `.year` component addition, NEVER
/// `addingTimeInterval` / raw 86400-second arithmetic) so results stay correct
/// across DST transitions; Bucharest-local semantics come from whichever
/// `Calendar` the caller passes in (production: `ScheduledItemStore` passes the
/// device calendar). The v2 Loans phase builds payment series on top of this
/// seam - keep it pure, no ModelContext creeping in here.
enum RecurrenceEngine {

    /// The next due date after `date` for `rule`, or `nil` for `.none`. Monthly /
    /// quarterly / yearly clamp to the last valid day of the target month (Jan 31
    /// + monthly -> Feb 28, or Feb 29 in a leap year; Aug 31 + monthly -> Sep 30)
    /// instead of Foundation's default month-overflow rollover, which would push
    /// Jan 31 + 1 month into early March.
    static func nextDueDate(after date: Date, rule: RecurrenceRule, calendar: Calendar) -> Date? {
        switch rule {
        case .none: return nil
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: return addClampedMonths(1, to: date, calendar: calendar)
        case .quarterly: return addClampedMonths(3, to: date, calendar: calendar)
        case .yearly: return addClampedMonths(12, to: date, calendar: calendar)
        }
    }

    /// A new pending `ScheduledItem` for the next occurrence in `item`'s series,
    /// or `nil` when `item` doesn't recur. Copies title / amount / currency /
    /// direction / counterparty / projectID / recurrence; advances `dueDate` from
    /// `item.dueDate` (never from "now" - an overdue item marked done late still
    /// recurs on its original schedule, not from today).
    ///
    /// PURE: does not mutate `item`. The returned occurrence's `seriesID` is
    /// `item.seriesID` when already set, else a freshly minted `UUID` - the
    /// caller (`ScheduledItemStore.markDone`) is responsible for writing that
    /// same minted id back onto the origin item, so a re-entrant mark-done call
    /// on the same origin item stays idempotent (the no-duplicate guard).
    static func makeNextOccurrence(from item: ScheduledItem, calendar: Calendar) -> ScheduledItem? {
        guard item.recurrence != .none,
              let next = nextDueDate(after: item.dueDate, rule: item.recurrence, calendar: calendar)
        else { return nil }
        return ScheduledItem(
            direction: item.direction,
            amount: item.amount,
            currency: item.currency,
            title: item.title,
            descriptionText: item.descriptionText,
            counterparty: item.counterparty,
            dueDate: next,
            projectID: item.projectID,
            status: .pending,
            recurrence: item.recurrence,
            seriesID: item.seriesID ?? UUID()
        )
    }

    // MARK: - Month-end clamped addition

    /// Adds `months` to `date`, clamping the day-of-month to the last valid day
    /// of the resulting month (rather than Foundation's default rollover
    /// behaviour, which turns Jan 31 + 1 month into early March). Preserves
    /// time-of-day. Reused for monthly (+1), quarterly (+3), and yearly (+12) so
    /// a Feb 29 due date correctly clamps to Feb 28 on a non-leap target year.
    private static func addClampedMonths(_ months: Int, to date: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }

        let totalMonths = year * 12 + (month - 1) + months
        let targetYear = totalMonths / 12
        let targetMonth = totalMonths % 12 + 1

        guard let firstOfTargetMonth = calendar.date(from: DateComponents(year: targetYear, month: targetMonth, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfTargetMonth)
        else { return nil }

        comps.year = targetYear
        comps.month = targetMonth
        comps.day = min(day, dayRange.count)
        return calendar.date(from: comps)
    }
}
