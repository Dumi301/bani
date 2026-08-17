import Foundation

/// Pure scheduling logic for payment reminders — deterministic identifiers, the
/// 09:00-local trigger, and the localized copy — with NO `UNUserNotificationCenter`
/// dependency, so every rule is unit-testable and CI never attempts real delivery
/// (`ReminderService` is the thin side-effecting wrapper). One notification per
/// pending `ScheduledItem`, fired at 09:00 local on its due date.
enum NotificationScheduler {

    /// Every Bani reminder request id starts with this, so a disable can cancel
    /// exactly Bani's pending notifications and nothing else on the device.
    static let identifierPrefix = "bani.reminder."

    /// `userInfo` key carrying the item id, so tapping a notification can open it.
    static let itemIDUserInfoKey = "scheduledItemID"

    /// The deterministic request id for one item — stable across reschedules, so
    /// editing an item replaces (never duplicates) its pending notification.
    static func identifier(for itemID: UUID) -> String {
        identifierPrefix + itemID.uuidString
    }

    /// Whether a request id belongs to Bani (cancel scoping).
    static func isBaniReminder(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// 09:00 local on the due date, or `nil` for a non-pending item.
    static func fireDate(for item: ScheduledItemSnapshot, calendar: Calendar = .current) -> Date? {
        guard item.status == .pending else { return nil }
        let day = calendar.startOfDay(for: item.dueDate)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    }

    /// The calendar trigger components (09:00 local on due date), or `nil` when the
    /// item is not pending.
    static func triggerComponents(for item: ScheduledItemSnapshot, calendar: Calendar = .current) -> DateComponents? {
        guard let fire = fireDate(for: item, calendar: calendar) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: fire)
        comps.hour = 9
        comps.minute = 0
        return comps
    }

    /// Whether this item should carry a scheduled notification given `now`: pending
    /// AND its 09:00 fire time is still in the future. An overdue item is NOT
    /// scheduled — it surfaces as an in-app overdue flag instead (which works
    /// regardless of the reminders toggle).
    static func shouldSchedule(_ item: ScheduledItemSnapshot, now: Date, calendar: Calendar = .current) -> Bool {
        guard let fire = fireDate(for: item, calendar: calendar) else { return false }
        return fire > now
    }

    // MARK: - Localized copy (ro + en)

    /// Notification title — "De plătit azi" (outgoing) / "De încasat azi" (incoming).
    static func title(for item: ScheduledItemSnapshot) -> String {
        switch item.direction {
        case .outgoing: String(localized: "reminder.title.outgoing")
        case .incoming: String(localized: "reminder.title.incoming")
        }
    }

    /// Notification body — "Ion — 6.000 RON (Proiect Manhattan)". Uses the
    /// counterparty when present, else the item title; appends the project in
    /// parentheses when one is assigned.
    static func body(for item: ScheduledItemSnapshot, projectName: String?) -> String {
        let amount = item.amount.formatted(.number.precision(.fractionLength(0...2)))
        let who: String = {
            if let cp = item.counterparty?.trimmingCharacters(in: .whitespaces), !cp.isEmpty { return cp }
            return item.title
        }()
        var line = "\(who) — \(amount) \(item.currency.displayCode)"
        if let projectName, !projectName.isEmpty {
            line += " (\(projectName))"
        }
        return line
    }
}
