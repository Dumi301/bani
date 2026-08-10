import SwiftUI

/// Settings tab: appearance override, Whisper model status, app version.
/// Reads `WhisperService` from the environment (owned by Unit B); the
/// appearance picker writes the same `"appearanceMode"` `@AppStorage` key
/// the frozen `BaniApp` root already reads via `.preferredColorScheme` —
/// this view never touches `Bani/App/`.
struct SettingsView: View {
    @Environment(WhisperService.self) private var whisper
    @Environment(\.metrics) private var metrics

    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
    /// In-app language override (B2).
    @AppStorage("appLanguage") private var appLanguageRaw: String = AppLanguage.system.rawValue
    /// Transcription-language override (A1). Auto = constrained RO/EN detection;
    /// non-Auto forces the Whisper decoder language.
    @AppStorage(TranscriptionLanguage.storageKey) private var transcriptionLanguageRaw: String = TranscriptionLanguage.auto.rawValue
    /// Auto-save countdown length for the confirmation card, in seconds (2–8).
    /// `ConfirmationCard` reads the same key; default 4 s.
    @AppStorage("confirmationDuration") private var confirmationDuration: Double = ConfirmationCard.defaultAutoSaveDelay
    /// Last voice-pipeline outcome (transcript+parse, or the thrown error),
    /// written by `VoiceSessionLog.record` on every voice attempt (A3).
    @AppStorage(VoiceSessionLog.appStorageKey) private var lastVoiceSession: String = ""
    /// Recording forensics for that same attempt (duration, bytes, sample rate,
    /// avg/peak RMS) — discriminates an empty/mis-formatted/clipped file from a
    /// genuinely silent one if the "No speech detected" bug ever recurs.
    @AppStorage(VoiceSessionLog.forensicsKey) private var lastVoiceForensics: String = ""
    /// The A1 refinement pair (raw → refined) for the last voice attempt — shown
    /// only when the refiner changed the transcript, so a mishear-vs-clean is
    /// spottable on-device.
    @AppStorage(VoiceSessionLog.refinementKey) private var lastVoiceRefinement: String = ""
    /// Layout density (B2). Writes the same `"designScale"` key the app root reads,
    /// so the choice applies live across every surface.
    @AppStorage("designScale") private var designScaleRaw: String = DesignScale.balanced.rawValue

    /// UI-test seam: `-importUITest` auto-presents the import wizard so the flow can
    /// be exercised without driving the system document picker.
    @State private var autoPresentImport = ProcessInfo.processInfo.arguments.contains("-importUITest")

    private var appearance: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    /// The in-app language (B2). Setting it persists the choice and applies it to
    /// `AppleLanguages`; the root `.environment(\.locale,…)` switches the app's own
    /// strings live off the same `@AppStorage` key.
    private var appLanguage: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage.from(appLanguageRaw) },
            set: { newValue in
                appLanguageRaw = newValue.rawValue
                LanguageController.apply(newValue)
            }
        )
    }

    private var designScale: Binding<DesignScale> {
        Binding(
            get: { DesignScale(rawValue: designScaleRaw) ?? .balanced },
            set: { designScaleRaw = $0.rawValue }
        )
    }

    /// Transcription language (A1). Setting it persists the choice; the next
    /// recording reads `TranscriptionLanguage.active` in `WhisperService`.
    private var transcriptionLanguage: Binding<TranscriptionLanguage> {
        Binding(
            get: { TranscriptionLanguage(rawValue: transcriptionLanguageRaw) ?? .auto },
            set: { transcriptionLanguageRaw = $0.rawValue }
        )
    }

    /// Selected transcription model (B). Setting it routes through
    /// `WhisperService.select`, which downloads the chosen variant if needed.
    private var modelVariant: Binding<WhisperModelVariant> {
        Binding(
            get: { whisper.activeVariant },
            set: { newValue in Task { await whisper.select(newValue) } }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Recording
                Section {
                    Picker("Transcription model", selection: modelVariant) {
                        ForEach(WhisperModelVariant.allCases) { variant in
                            Text(variant.label).tag(variant)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.modelVariantPicker")

                    Text(whisper.activeVariant.blurb)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Palette.surface)

                    Picker("settings.transcriptionLanguage", selection: transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.transcriptionLanguagePicker")

                    modelStatusRow
                        .accessibilityIdentifier("settings.modelStatusRow")

                    VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                        HStack {
                            Text("Confirmation time")
                                .font(.system(.body).weight(.medium))
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            Text("\(Int(confirmationDuration.rounded())) s")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Palette.secondaryInk)
                        }
                        Slider(value: $confirmationDuration, in: ConfirmationCard.minAutoSaveDelay...ConfirmationCard.maxAutoSaveDelay, step: 1)
                            .tint(Palette.accent)
                            .accessibilityIdentifier("settings.confirmationTimeSlider")
                            .accessibilityLabel("Confirmation time")
                            .accessibilityValue("\(Int(confirmationDuration.rounded())) seconds")
                    }
                    .padding(.vertical, metrics.rowVInset)
                    .listRowBackground(Palette.surface)
                } header: {
                    Text("settings.section.recording")
                        .foregroundStyle(Palette.secondaryInk)
                } footer: {
                    VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                        Text("Medium hears Romanian more accurately but is a larger download. Switching models downloads the chosen one if you don't already have it — manual entry works throughout.")
                        Text("settings.transcriptionLanguage.footer")
                        Text("How long the confirmation card waits before auto-saving. Tap the card to pause and edit.")
                    }
                    .foregroundStyle(Palette.secondaryInk)
                }

                // MARK: Appearance
                Section {
                    Picker("Appearance", selection: appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.appearancePicker")

                    Picker("settings.language", selection: appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.languagePicker")

                    Picker("settings.density", selection: designScale) {
                        ForEach(DesignScale.allCases) { scale in
                            Text(scale.label).tag(scale)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.densityPicker")
                } header: {
                    Text("settings.section.appearance")
                        .foregroundStyle(Palette.secondaryInk)
                } footer: {
                    VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                        Text("settings.language.footer")
                        Text("settings.density.footer")
                    }
                    .foregroundStyle(Palette.secondaryInk)
                }

                // MARK: Auto-logging (v1.1 Auto-Logging run)
                Section {
                    NavigationLink {
                        AutoLoggingGuideView()
                    } label: {
                        Label("autolog.settings.title", systemImage: "bolt.fill")
                            .foregroundStyle(Palette.ink)
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.autoLoggingRow")
                } header: {
                    Text("autolog.settings.title")
                        .foregroundStyle(Palette.secondaryInk)
                } footer: {
                    Text("autolog.settings.footer")
                        .foregroundStyle(Palette.secondaryInk)
                }

                // MARK: Categories
                Section {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("categories.title", systemImage: "square.grid.2x2")
                            .foregroundStyle(Palette.ink)
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.categoriesRow")
                } header: {
                    Text("categories.title")
                        .foregroundStyle(Palette.secondaryInk)
                }

                // MARK: Import history (v1.1)
                Section {
                    NavigationLink {
                        ImportHistoryView()
                    } label: {
                        Label("import.title", systemImage: "square.and.arrow.down")
                            .foregroundStyle(Palette.ink)
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.importRow")
                } header: {
                    Text("import.title")
                        .foregroundStyle(Palette.secondaryInk)
                }

                // MARK: Data & Decisions
                Section {
                    VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                        Text("Last voice session")
                            .font(.system(.body).weight(.medium))
                            .foregroundStyle(Palette.ink)
                        Text(lastVoiceSession.isEmpty ? String(localized: "settings.noVoiceEntries") : lastVoiceSession)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        if !lastVoiceRefinement.isEmpty {
                            Text(lastVoiceRefinement)
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryInk.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.lastVoiceRefinement")
                        }
                        if !lastVoiceForensics.isEmpty {
                            Text(lastVoiceForensics)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.secondaryInk.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.lastVoiceForensics")
                        }
                    }
                    .padding(.vertical, metrics.rowVInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Palette.surface)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.lastVoiceSessionRow")

                    NavigationLink {
                        DecisionsView()
                    } label: {
                        Text("Decisions")
                            .font(.system(.body).weight(.medium))
                            .foregroundStyle(Palette.ink)
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("settings.decisionsRow")
                } header: {
                    Text("settings.section.data")
                        .foregroundStyle(Palette.secondaryInk)
                }

                // MARK: About
                Section {
                    LabeledContent("Version") {
                        Text(appVersionString)
                            .foregroundStyle(Palette.secondaryInk)
                            .monospacedDigit()
                    }
                    .listRowBackground(Palette.surface)
                } header: {
                    Text("settings.section.about")
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .fullScreenCover(isPresented: $autoPresentImport) {
                ImportFlowView()
            }
        }
    }

    // MARK: - Model status row

    @ViewBuilder
    private var modelStatusRow: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                    Text("\(whisper.activeVariant.label) model")
                        .font(.system(.body).weight(.medium))
                        .foregroundStyle(Palette.ink)

                    Text(statusDescription)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Text(whisper.activeVariant.sizeLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.secondaryInk)
            }

            if case .downloading(let progress) = whisper.modelState {
                ProgressView(value: progress)
                    .tint(Palette.accent)
            }

            Button {
                Task { await whisper.redownloadModel() }
            } label: {
                Text(whisper.isModelDownloaded ? String(localized: "model.redownload") : String(localized: "model.download"))
                    .font(.system(.subheadline).weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(Palette.accent)
            .disabled(isDownloading)
        }
        .padding(.vertical, metrics.rowVInset)
        .listRowBackground(Palette.surface)
    }

    private var isDownloading: Bool {
        if case .downloading = whisper.modelState { return true }
        return false
    }

    private var statusDescription: String {
        switch whisper.modelState {
        case .notReady:
            String(localized: "model.status.notReady")
        case .downloading(let progress):
            "\(String(localized: "model.status.downloading")) \(Int(progress * 100))%"
        case .ready:
            String(localized: "model.status.ready")
        case .failed(let message):
            String(localized: "model.status.failed \(message)")
        }
    }

    private var statusColor: Color {
        switch whisper.modelState {
        case .ready:
            Palette.accent
        case .failed:
            Palette.secondaryInk
        default:
            Palette.secondaryInk
        }
    }

    // MARK: - App version

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(WhisperService(modelAbsent: true))
}
