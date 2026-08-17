import Foundation
import SwiftData
import UserNotifications

/// The thin, side-effecting wrapper around `UNUserNotificationCenter` for payment
/// reminders. All the *logic* (identifiers, the 09:00 trigger, copy) lives in the
/// pure `NotificationScheduler`; this type only talks to the system. Default OFF —
/// nothing is scheduled until the Settings toggle enables it AND permission is
/// granted. In CI there is no real delivery (the pure scheduler is what's tested).
enum ReminderService {

    /// `@AppStorage` key for the master toggle (Settings → Payment reminders).
    static let enabledKey = "paymentRemindersEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: - Authorization

    /// Request notification permission; returns whether it was granted.
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    /// Cancel every pending Bani reminder (used on disable + before each refresh).
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter(NotificationScheduler.isBaniReminder)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Read the store on the main actor, then reschedule off it. Safe to call after
    /// any add / edit / mark-done / delete — a no-op while the toggle is OFF.
    @MainActor
    static func refreshFromStore(_ modelContext: ModelContext) {
        let items = ((try? modelContext.fetch(FetchDescriptor<ScheduledItem>())) ?? []).map(\.snapshot)
        var names: [UUID: String] = [:]
        for project in (try? modelContext.fetch(FetchDescriptor<Project>())) ?? [] {
            names[project.id] = project.name
        }
        Task { await apply(items: items, projectNames: names) }
    }

    /// Cancel all Bani reminders, then (only when enabled + authorized) schedule one
    /// per pending, still-future item at 09:00 local on its due date.
    static func apply(items: [ScheduledItemSnapshot], projectNames: [UUID: String], now: Date = Date()) async {
        await cancelAll()
        guard isEnabled else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let center = UNUserNotificationCenter.current()
        for item in items where NotificationScheduler.shouldSchedule(item, now: now) {
            guard let comps = NotificationScheduler.triggerComponents(for: item) else { continue }
            let content = UNMutableNotificationContent()
            content.title = NotificationScheduler.title(for: item)
            content.body = NotificationScheduler.body(
                for: item,
                projectName: item.projectID.flatMap { projectNames[$0] }
            )
            content.sound = .default
            content.userInfo = [NotificationScheduler.itemIDUserInfoKey: item.id.uuidString]
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: NotificationScheduler.identifier(for: item.id),
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
