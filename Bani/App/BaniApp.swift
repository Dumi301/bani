import SwiftUI
import SwiftData

/// App entry point. Phase-0 frozen shell + the single controlled INTEGRATION
/// edit (orchestrator-owned): it injects the two shared `@Observable` services
/// (`WhisperService`, `RateService`) into the environment, kicks off the
/// non-blocking first-launch model download, and refreshes the BNR rate on
/// launch + foreground. Workers never edit this file.
///
/// Recognised launch arguments (used by ScreenshotTests / UI tests):
///   -uiTesting            → in-memory store (no disk persistence)
///   -seedSampleData       → seed deterministic sample transactions
///   -appearance <mode>    → force system|light|dark
///   -forceRuleParser      → (read by the Log feature) force RuleBasedParser
///   -modelAbsent          → never touch WhisperKit; skips the first-launch download screen
@main
struct BaniApp: App {
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
    @AppStorage("hasCompletedFirstLaunch") private var hasCompletedFirstLaunch: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer
    private let modelAbsent: Bool

    @State private var whisper: WhisperService
    @State private var rates: RateService

    @MainActor
    init() {
        let args = ProcessInfo.processInfo.arguments
        let inMemory = args.contains("-uiTesting")
        let absent = args.contains("-modelAbsent")
        self.modelAbsent = absent

        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
            // CategoryRule + the feedback-ledger entities (DecisionRecord,
            // ContextRule, CorrectionMemory) join the schema as separate, additive
            // entities — `Transaction` is unchanged, so this stays a lightweight
            // migration; existing rows are untouched.
            container = try ModelContainer(
                for: Transaction.self, CategoryRule.self,
                DecisionRecord.self, ContextRule.self, CorrectionMemory.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        if let idx = args.firstIndex(of: "-appearance"), idx + 1 < args.count {
            UserDefaults.standard.set(args[idx + 1], forKey: "appearanceMode")
        }
        if args.contains("-seedSampleData") {
            SampleData.seed(into: container)
        }
        // Deterministic BNR rate for UI tests (no network) so the detail view's
        // currency-conversion line renders. Read by RateService.init below.
        if args.contains("-seedRate") {
            UserDefaults.standard.set(4.97, forKey: "bnr.rate")
            UserDefaults.standard.set("2026-07-29", forKey: "bnr.date")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "bnr.fetchedAt")
        }

        _whisper = State(initialValue: WhisperService(modelAbsent: absent))
        _rates = State(initialValue: RateService())
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    /// First launch shows the model-download screen once (never in UI tests /
    /// `-modelAbsent`, so screenshots capture the real tabs).
    private var showFirstLaunchDownload: Binding<Bool> {
        Binding(
            get: { !hasCompletedFirstLaunch && !modelAbsent },
            set: { presented in if !presented { hasCompletedFirstLaunch = true } }
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .tint(Color("BaniAccent"))
                .environment(whisper)
                .environment(rates)
                .preferredColorScheme(appearance.colorScheme)
                .fullScreenCover(isPresented: showFirstLaunchDownload) {
                    ModelDownloadView(onContinue: { hasCompletedFirstLaunch = true })
                        .environment(whisper)
                }
                .task {
                    // One-shot cleanup (A2): strip leaked Whisper tokens from
                    // stored transactions and delete token-artifact learned
                    // rules. Guarded internally — runs once per install.
                    TokenCleanupMigration.runIfNeeded(container.mainContext)
                    // Seed the categorizer's keyword table off the launch
                    // critical path (idempotent — a no-op once rules exist).
                    CategoryRuleStore.seedIfNeeded(container.mainContext)
                    if !modelAbsent {
                        await whisper.prepareModelIfNeeded()
                    }
                    // Skip the BNR network refresh under UI tests: CI simulators
                    // have no egress, so a hung request keeps the app from going
                    // idle and flakes the UI tests. Tests needing a rate use -seedRate.
                    if !ProcessInfo.processInfo.arguments.contains("-uiTesting") {
                        await rates.refreshIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await rates.refreshIfNeeded() }
                    }
                }
        }
        .modelContainer(container)
    }
}
