import SwiftUI
import SwiftData

/// Four-tab shell: Log / Projects / Finances / Settings. The Projects tab (v1.2a)
/// sits between Log and Finances and carries a subtle overdue badge whenever any
/// pending scheduled item is past due — this in-app flag works REGARDLESS of the
/// payment-reminders toggle (the toggle only governs local notifications).
struct RootTabView: View {
    @Query private var scheduledItems: [ScheduledItem]

    /// Count of pending, past-due scheduled items — the tab-icon badge.
    private var overdueCount: Int {
        scheduledItems.filter { $0.isOverdue() }.count
    }

    var body: some View {
        TabView {
            LogView()
                .tabItem { Label("Log", systemImage: "mic.fill") }

            ProjectsView()
                .tabItem { Label("projects.title", systemImage: "folder.fill") }
                .badge(overdueCount)

            FinancesView()
                .tabItem { Label("Finances", systemImage: "chart.pie.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

#Preview {
    RootTabView()
}
