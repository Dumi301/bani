import SwiftUI

/// Three-tab shell: Log / Finances / Settings. Phase-0 FROZEN.
/// References `LogView`, `FinancesView`, `SettingsView` by their stable type
/// names — worker units C/D/E replace the stub bodies of those views without
/// touching this file.
struct RootTabView: View {
    var body: some View {
        TabView {
            LogView()
                .tabItem { Label("Log", systemImage: "mic.fill") }

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
