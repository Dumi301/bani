import SwiftUI
import SwiftData

/// App entry point. Phase-0 frozen shell + the single controlled INTEGRATION
/// edit (orchestrator-owned): it injects the two shared `@Observable` services
/// (`WhisperService`, `RateService`) into the environment, kicks off the
/// non-blocking first-launch model download, and refreshes the BNR rate on
/// launch + foreground. Workers never edit this file — SEAL (V2 push) is a
/// one-time, orchestrator-authorized exception adding the opportunistic
/// bank-sync foreground pull (`syncBankIfNeeded()`) that `BankLinkView`'s
/// header comment already promises the root wires up.
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
    /// Layout density (B2) — Airy / Balanced / Dense. Drives the design-scale
    /// token system app-wide via `.environment(\.designScale,…)`; a change
    /// applies live, no restart.
    @AppStorage("designScale") private var designScaleRaw: String = DesignScale.balanced.rawValue
    /// In-app language override (B2). Drives the root `.environment(\.locale,…)`
    /// so a change applies live, without a reinstall.
    @AppStorage("appLanguage") private var appLanguageRaw: String = AppLanguage.system.rawValue
    @AppStorage("hasCompletedFirstLaunch") private var hasCompletedFirstLaunch: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer
    private let modelAbsent: Bool

    @State private var whisper: WhisperService
    @State private var rates: RateService
    /// H1 (phase-A): the foreground bank-sync throttle gate. Stateless wrapper
    /// over `UserDefaults.standard` (see `BankSyncGate`), so a plain `let` is
    /// safe here the same way `container`/`modelAbsent` already are.
    private let bankSyncGate = BankSyncGate()

    @MainActor
    init() {
        let args = ProcessInfo.processInfo.arguments
        let inMemory = args.contains("-uiTesting")
        let absent = args.contains("-modelAbsent")
        self.modelAbsent = absent

        do {
            // v1.1 Auto-Logging (controlled integration edit): the on-disk store is
            // now owned by `BaniModelContainer.shared` so the background
            // `LogPaymentIntent` launch and this foreground launch share exactly ONE
            // container over the default store (see BaniModelContainer). The schema
            // is unchanged from before this run (same default URL → existing data
            // preserved); only `TransactionSource` gained the additive `.autoLogged`
            // case. UI tests keep their own throwaway in-memory container.
            if inMemory {
                container = try BaniModelContainer.make(inMemory: true)
            } else {
                container = BaniModelContainer.shared
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        if let idx = args.firstIndex(of: "-appearance"), idx + 1 < args.count {
            UserDefaults.standard.set(args[idx + 1], forKey: "appearanceMode")
        }
        // -designScale <airy|balanced|dense> (test seam for the B1 density matrix).
        if let idx = args.firstIndex(of: "-designScale"), idx + 1 < args.count {
            UserDefaults.standard.set(args[idx + 1], forKey: "designScale")
        }
        // -appLanguage <ro|en|system> (test seam for the B5 Romanian screenshots).
        if let idx = args.firstIndex(of: "-appLanguage"), idx + 1 < args.count {
            let language = AppLanguage.fromCode(args[idx + 1])
            UserDefaults.standard.set(language.rawValue, forKey: LanguageController.storageKey)
        }
        // Apply the persisted (or just-overridden) language to AppleLanguages so a
        // cold launch resolves the right .lproj before the first frame; the live
        // switch is handled by the root `.environment(\.locale,…)` below.
        LanguageController.apply(AppLanguage.from(UserDefaults.standard.string(forKey: LanguageController.storageKey)))
        // Screenshot seam: open the Finances chart on the bars view so the A4
        // bar-interaction matrix (selected bar + annotation) can be captured.
        if args.contains("-uiTestBars") {
            UserDefaults.standard.set(ChartKind.bars.rawValue, forKey: "financesChartType")
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

    /// The active layout density (B2), injected into the whole view tree.
    private var designScale: DesignScale {
        DesignScale(rawValue: designScaleRaw) ?? .balanced
    }

    /// The locale pushed into the whole view tree for the chosen in-app language
    /// (B2/B3) — switches SwiftUI string lookup AND every date/number/currency
    /// FormatStyle to the selected language, live, with no reinstall.
    private var appLocale: Locale {
        LanguageController.resolvedLocale(AppLanguage.from(appLanguageRaw))
    }

    /// First launch shows the model-download screen once (never in UI tests /
    /// `-modelAbsent`, so screenshots capture the real tabs).
    private var showFirstLaunchDownload: Binding<Bool> {
        Binding(
            get: { !hasCompletedFirstLaunch && !modelAbsent },
            set: { presented in if !presented { hasCompletedFirstLaunch = true } }
        )
    }

    /// SEAL (V2 push, orchestrator-authorized addition to this otherwise-frozen
    /// file): the app-foreground opportunistic pull `BankLinkView`'s own doc
    /// comment promises ("Pull is manual … the app-foreground opportunistic pull
    /// is wired by the root"). Mirrors `BankLinkView.syncNow()`'s call shape
    /// exactly (accountIDs from the persisted `BankLink` row + a fresh
    /// `EnableBankingClient(secrets:)`), fire-and-forget from `scenePhase`. Inert
    /// (no network, no work) without stored credentials — `sync` itself is also
    /// silent-fail, so this never surfaces to the UI.
    ///
    /// H1 (phase-A, orchestrator-authorized addition): gated by `bankSyncGate`
    /// so this opportunistic pull runs at most once per
    /// `BankSyncGate.minInterval` (6h) — Enable Banking rate-limits the
    /// transaction endpoint per account/day, and every foreground was
    /// calling `sync` unconditionally, exhausting the quota within a handful
    /// of app opens and killing the feed for the rest of the day with no
    /// visible symptom (the 429 was silently absorbed into
    /// `BankSyncOutcome.hadError`). `BankLinkView.syncNow()` — the manual
    /// "Sync now" path — calls `BankSyncService.sync` directly and never
    /// consults this gate.
    @MainActor
    private func syncBankIfNeeded() async {
        let keychain = KeychainStore()
        guard keychain.hasCredentials else { return }
        guard bankSyncGate.shouldSync() else { return }
        let accountIDs = (try? container.mainContext.fetch(FetchDescriptor<BankLink>()))?
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .accountIDs ?? []
        let client = EnableBankingClient(secrets: keychain)
        let service = BankSyncService(modelContainer: container)
        let outcome = await service.sync(accountIDs: accountIDs, client: client)
        bankSyncGate.recordOutcome(outcome)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .tint(Color("BaniAccent"))
                .environment(whisper)
                .environment(rates)
                .environment(\.locale, appLocale)
                .environment(\.designScale, designScale)
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
                    // C2 — pre-seed the ~16 real-estate/finance custom categories +
                    // their OBSERVATII keyword rules on first launch (idempotent,
                    // marker-gated). Ordered AFTER the preset seed so preset rules
                    // seed first; upgraders still get the customs.
                    PresetSeeding.seedIfNeeded(container.mainContext)
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
                        Task { await syncBankIfNeeded() }
                    }
                }
        }
        .modelContainer(container)
    }
}
