import SwiftUI

/// Settings tab: appearance override, Whisper model status, app version.
/// Reads `WhisperService` from the environment (owned by Unit B); the
/// appearance picker writes the same `"appearanceMode"` `@AppStorage` key
/// the frozen `BaniApp` root already reads via `.preferredColorScheme` —
/// this view never touches `Bani/App/`.
struct SettingsView: View {
    @Environment(WhisperService.self) private var whisper

    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
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

    private var appearance: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
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
                    modelStatusRow
                        .accessibilityIdentifier("settings.modelStatusRow")
                } header: {
                    Text("Speech Model")
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last voice session")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(Color("BaniInk"))
                        Text(lastVoiceSession.isEmpty ? "No voice entries yet" : lastVoiceSession)
                            .font(.subheadline)
                            .foregroundStyle(Color("BaniSecondaryInk"))
                            .fixedSize(horizontal: false, vertical: true)
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
                    Text("Whisper Model")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(Color("BaniInk"))

                    Text(statusDescription)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Text("~\(whisper.modelSizeMB) MB")
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
                Text(whisper.isModelDownloaded ? "Re-download Model" : "Download Model")
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
            "Not downloaded"
        case .downloading(let progress):
            "Downloading… \(Int(progress * 100))%"
        case .ready:
            "Downloaded"
        case .failed(let message):
            "Failed — \(message)"
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
