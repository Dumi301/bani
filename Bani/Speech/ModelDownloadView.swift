import SwiftUI

/// First-launch model download progress screen (see `## SPEECH & WHISPER`
/// and `## DESIGN SYSTEM & THEME` in `pipeline/spec.md`). Non-blocking: a
/// "Skip — enter manually" affordance is always available, and `onContinue`
/// fires both when the user taps it and once the model reaches `.ready`, so
/// the caller can dismiss straight into the app either way. No onboarding
/// carousel — this is the entire first-launch experience before the tab shell.
struct ModelDownloadView: View {
    @Environment(WhisperService.self) private var whisper
    var onContinue: () -> Void

    var body: some View {
        ZStack {
            Color("BaniCanvas").ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Color("BaniAccent"))

                    Text("Setting up voice logging")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color("BaniInk"))
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color("BaniSecondaryInk"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                progressSection
                    .padding(.horizontal, 40)
                    .frame(minHeight: 60)

                Spacer()

                VStack(spacing: 16) {
                    if case .failed = whisper.modelState {
                        Button {
                            Task { await whisper.redownloadModel() }
                        } label: {
                            Text("Try Again")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("BaniAccent"))
                        .padding(.horizontal, 40)
                    }

                    Button(action: onContinue) {
                        Text("Skip — enter manually")
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .foregroundStyle(Color("BaniSecondaryInk"))
                    }
                    .accessibilityHint("Continues to the app; transactions can be typed instead of spoken.")
                }
                .padding(.bottom, 24)
            }
        }
        .task {
            await whisper.prepareModelIfNeeded()
        }
        .onChange(of: whisper.modelState) { _, newState in
            if newState == .ready {
                onContinue()
            }
        }
        .animation(.spring(duration: 0.4), value: whisper.modelState)
    }

    @ViewBuilder
    private var progressSection: some View {
        switch whisper.modelState {
        case .notReady:
            ProgressView()
                .tint(Color("BaniAccent"))

        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(Color("BaniAccent"))
                Text("\(Int(progress * 100))% of ~\(whisper.modelSizeMB) MB")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color("BaniSecondaryInk"))
            }

        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(Color("BaniAccent"))

        case .failed(let message):
            VStack(spacing: 8) {
                Label("Couldn't download the voice model", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color("BaniInk"))
                Text(message)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var subtitle: String {
        String(localized: "download.subtitle")
    }
}
