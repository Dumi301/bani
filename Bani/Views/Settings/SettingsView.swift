import SwiftUI

/// Settings tab: appearance override, Whisper model status, app version.
/// Reads `WhisperService` from the environment (owned by Unit B); the
/// appearance picker writes the same `"appearanceMode"` `@AppStorage` key
/// the frozen `BaniApp` root already reads via `.preferredColorScheme` —
/// this view never touches `Bani/App/`.
struct SettingsView: View {
    @Environment(WhisperService.self) private var whisper

    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
    /// In-app language override (B2).
    @AppStorage("appLanguage") private var appLanguageRaw: String = AppLanguage.system.rawValue
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
                Section {
                    Picker("Appearance", selection: appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color("BaniSurface"))
                    .accessibilityIdentifier("settings.appearancePicker")
                } header: {
                    Text("Appearance")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    Picker("settings.language", selection: appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .listRowBackground(Color("BaniSurface"))
                    .accessibilityIdentifier("settings.languagePicker")
                } header: {
                    Text("settings.language")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                } footer: {
                    Text("settings.language.footer")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("categories.title", systemImage: "square.grid.2x2")
                            .foregroundStyle(Color("BaniInk"))
                    }
                    .listRowBackground(Color("BaniSurface"))
                    .accessibilityIdentifier("settings.categoriesRow")
                } header: {
                    Text("categories.title")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Confirmation time")
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundStyle(Color("BaniInk"))
                            Spacer()
                            Text("\(Int(confirmationDuration.rounded())) s")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Color("BaniSecondaryInk"))
                        }
                        Slider(value: $confirmationDuration, in: ConfirmationCard.minAutoSaveDelay...ConfirmationCard.maxAutoSaveDelay, step: 1)
                            .tint(Color("BaniAccent"))
                            .accessibilityIdentifier("settings.confirmationTimeSlider")
                            .accessibilityLabel("Confirmation time")
                            .accessibilityValue("\(Int(confirmationDuration.rounded())) seconds")
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color("BaniSurface"))
                } header: {
                    Text("Logging")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                } footer: {
                    Text("How long the confirmation card waits before auto-saving. Tap the card to pause and edit.")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    Picker("Transcription model", selection: modelVariant) {
                        ForEach(WhisperModelVariant.allCases) { variant in
                            Text(variant.label).tag(variant)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color("BaniSurface"))
                    .accessibilityIdentifier("settings.modelVariantPicker")

                    Text(whisper.activeVariant.blurb)
                        .font(.footnote)
                        .foregroundStyle(Color("BaniSecondaryInk"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color("BaniSurface"))

                    modelStatusRow
                        .accessibilityIdentifier("settings.modelStatusRow")
                } header: {
                    Text("Speech Model")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                } footer: {
                    Text("Medium hears Romanian more accurately but is a larger download. Switching models downloads the chosen one if you don't already have it — manual entry works throughout.")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last voice session")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(Color("BaniInk"))
                        Text(lastVoiceSession.isEmpty ? String(localized: "settings.noVoiceEntries") : lastVoiceSession)
                            .font(.subheadline)
                            .foregroundStyle(Color("BaniSecondaryInk"))
                            .fixedSize(horizontal: false, vertical: true)
                        if !lastVoiceRefinement.isEmpty {
                            Text(lastVoiceRefinement)
                                .font(.caption)
                                .foregroundStyle(Color("BaniSecondaryInk").opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.lastVoiceRefinement")
                        }
                        if !lastVoiceForensics.isEmpty {
                            Text(lastVoiceForensics)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color("BaniSecondaryInk").opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.lastVoiceForensics")
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color("BaniSurface"))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.lastVoiceSessionRow")

                    NavigationLink {
                        DecisionsView()
                    } label: {
                        Text("Decisions")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(Color("BaniInk"))
                    }
                    .listRowBackground(Color("BaniSurface"))
                    .accessibilityIdentifier("settings.decisionsRow")
                } header: {
                    Text("Diagnostics")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    LabeledContent("Version") {
                        Text(appVersionString)
                            .foregroundStyle(Color("BaniSecondaryInk"))
                            .monospacedDigit()
                    }
                    .listRowBackground(Color("BaniSurface"))
                } header: {
                    Text("About")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color("BaniCanvas").ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }

    // MARK: - Model status row

    @ViewBuilder
    private var modelStatusRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(whisper.activeVariant.label) model")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(Color("BaniInk"))

                    Text(statusDescription)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Text(whisper.activeVariant.sizeLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color("BaniSecondaryInk"))
            }

            if case .downloading(let progress) = whisper.modelState {
                ProgressView(value: progress)
                    .tint(Color("BaniAccent"))
            }

            Button {
                Task { await whisper.redownloadModel() }
            } label: {
                Text(whisper.isModelDownloaded ? String(localized: "model.redownload") : String(localized: "model.download"))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(Color("BaniAccent"))
            .disabled(isDownloading)
        }
        .padding(.vertical, 8)
        .listRowBackground(Color("BaniSurface"))
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
            Color("BaniAccent")
        case .failed:
            Color("BaniSecondaryInk")
        default:
            Color("BaniSecondaryInk")
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
