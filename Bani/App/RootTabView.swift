import SwiftUI
import SwiftData

/// The v2-teardown tab identity, in tab-bar order. Extracted as a `CaseIterable`
/// enum so the structure ("4 tabs, Raport first, no Finances tab") is asserted in
/// `RootTabNavigationTests` without instantiating SwiftUI. `Finances` is DELIBERATELY
/// absent — it is now a drill-down inside the Raport hub, not a tab.
enum RootTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case raport   // the app's face (VISION §2): the living report
    case log      // capture — the launch tab (Bani's "absorb reality as it comes")
    case projects // the analytical spine
    case settings

    var id: String { rawValue }
}

/// Four-tab shell (v2 teardown): **Raport · Log · Projects · Settings**. The Raport
/// hub is the leftmost face AND the launch tab (E1) — the living report is the
/// app's face (VISION §2). Capture (Log) is one tap away; the old Finances tab
/// is removed and lives on as a drill-down inside the hub ("All transactions").
///
/// The Projects tab carries a subtle overdue badge whenever any pending scheduled
/// item is past due; this in-app flag works REGARDLESS of the payment-reminders
/// toggle (the toggle only governs local notifications).
struct RootTabView: View {
    @Query private var scheduledItems: [ScheduledItem]

    /// Launch on Raport (E1 — flips the prior Log-first default per the P7
    /// review-packet flag). Both `ManualEntryUITests` and
    /// `RecordingCrashRegressionUITests` navigate to the Log tab themselves
    /// after launch before driving their respective flows.
    @State private var selection: RootTab = .raport

    /// Count of pending, past-due scheduled items — the tab-icon badge.
    private var overdueCount: Int {
        scheduledItems.filter { $0.isOverdue() }.count
    }

    var body: some View {
        TabView(selection: $selection) {
            RaportHubView()
                .tag(RootTab.raport)
                .tabItem { Label("raport.tab.title", systemImage: "doc.text.below.ecg") }

            LogView()
                .tag(RootTab.log)
                .tabItem { Label("Log", systemImage: "mic.fill") }

            ProjectsView()
                .tag(RootTab.projects)
                .tabItem { Label("projects.title", systemImage: "folder.fill") }
                .badge(overdueCount)

            SettingsView()
                .tag(RootTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

#Preview {
    RootTabView()
}
