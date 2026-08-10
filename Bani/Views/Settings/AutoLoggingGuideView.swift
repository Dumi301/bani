import SwiftUI
import SwiftData

/// Settings → "Auto-logging" (Part A5). Step-by-step setup for the iOS Shortcuts
/// personal automation that turns every Apple Pay tap into a logged Bani payment,
/// plus a "test intent" row that fires the write path with a sample payload so the
/// setup can be verified on-device without a real payment (the sample lands in the
/// Log tab's review chip).
struct AutoLoggingGuideView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics

    @State private var testConfirmation: String?

    private let steps: [LocalizedStringKey] = [
        "autolog.guide.step1",
        "autolog.guide.step2",
        "autolog.guide.step3",
        "autolog.guide.step4",
        "autolog.guide.step5",
        "autolog.guide.step6",
    ]

    var body: some View {
        Form {
            Section {
                Text("autolog.guide.intro")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Palette.surface)
            }

            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.footnote.weight(.bold).monospacedDigit())
                            .foregroundStyle(Palette.accent)
                            .frame(width: 22, height: 22)
                            .background(Palette.accent.opacity(0.14), in: Circle())
                        Text(step)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Palette.surface)
                }
            } header: {
                Text("autolog.guide.section.steps")
                    .foregroundStyle(Palette.secondaryInk)
            }

            Section {
                Button {
                    logTestPayment()
                } label: {
                    Label("autolog.guide.test.button", systemImage: "bolt.fill")
                        .font(.system(.body).weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("autolog.guide.testButton")

                if let testConfirmation {
                    Text(testConfirmation)
                        .font(.subheadline)
                        .foregroundStyle(Palette.accent)
                        .listRowBackground(Palette.surface)
                        .accessibilityIdentifier("autolog.guide.testConfirmation")
                }
            } footer: {
                Text("autolog.guide.test.note")
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("autolog.settings.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Fires the SAME write path the intent uses with a sample payload, so on-device
    /// setup can be verified without a real Apple Pay transaction.
    private func logTestPayment() {
        let payload = AutoLogPayload(
            amountText: "12,50",
            currencyCode: "RON",
            merchant: String(localized: "autolog.guide.test.merchant"),
            cardName: "•••• 1234",
            date: Date(),
            origin: .intent
        )
        _ = try? AutoLogWriter.log(payload, in: modelContext)
        testConfirmation = String(localized: "autolog.guide.test.done")
    }
}
