import SwiftUI
import SwiftData

/// App entry point. Phase-0 FROZEN — owns the ModelContainer, the appearance
/// override, and the UI-test launch-argument hooks (in-memory store, sample-data
/// seeding, forced appearance). Front-loaded so no worker needs to edit it.
///
/// Recognised launch arguments (used by ScreenshotTests / UI tests):
///   -uiTesting            → in-memory store (no disk persistence)
///   -seedSampleData       → seed deterministic sample transactions
///   -appearance <mode>    → force system|light|dark
///   -forceRuleParser      → (read by the Log feature) force RuleBasedParser
///   -modelAbsent          → (read by the Speech layer) skip Whisper model use
@main
struct BaniApp: App {
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue

    let container: ModelContainer

    init() {
        let args = ProcessInfo.processInfo.arguments
        let inMemory = args.contains("-uiTesting")

        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
            container = try ModelContainer(for: Transaction.self, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        if let idx = args.firstIndex(of: "-appearance"), idx + 1 < args.count {
            UserDefaults.standard.set(args[idx + 1], forKey: "appearanceMode")
        }
        if args.contains("-seedSampleData") {
            SampleData.seed(into: container)
        }
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .tint(Color("BaniAccent"))
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
    }
}
