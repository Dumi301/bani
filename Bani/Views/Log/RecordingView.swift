import SwiftUI
import Foundation

/// Full-screen recording UI shown immediately after a Personal/Work tap —
/// no intermediate screen. Animated waveform driven by `Recorder.level`;
/// tapping anywhere stops recording (manual stop). Auto-stop on 2s trailing
/// silence happens inside `Recorder` itself and surfaces as `.finished(url)`,
/// observed by `LogView` (the owner of this `Recorder` instance).
///
/// While `isProcessing` is true (transcribing after stop), the waveform is
/// swapped for a progress indicator; tap-to-stop is disabled.
struct RecordingView: View {
    let recorder: Recorder
    let context: TransactionContext
    let isProcessing: Bool

    var body: some View {
        ZStack {
            Color("BaniInk").ignoresSafeArea()

            VStack(spacing: 32) {
                Text(context.label)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color("BaniCanvas").opacity(0.7))

                if isProcessing {
                    ProgressView()
                        .tint(Color("BaniAccent"))
                        .scaleEffect(1.4)
                        .frame(height: 120)
                    Text("Understanding…")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color("BaniCanvas").opacity(0.6))
                } else {
                    waveform
                    Text("Listening…")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color("BaniCanvas").opacity(0.6))
                    Text("Tap to stop")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Color("BaniCanvas").opacity(0.4))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isProcessing else { return }
            recorder.stop()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isProcessing ? "Understanding your recording" : "Recording \(context.label) transaction. Tap to stop.")
        .accessibilityAddTraits(isProcessing ? [] : .isButton)
    }

    private var waveform: some View {
        HStack(spacing: 6) {
            ForEach(0..<24, id: \.self) { i in
                Capsule()
                    .fill(Color("BaniAccent"))
                    .frame(width: 5, height: barHeight(for: i))
            }
        }
        .frame(height: 120)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: recorder.level)
    }

    /// Per-bar height derived from the single `Recorder.level` sample plus a
    /// fixed per-index variance so the bars don't move in lockstep — this is
    /// purely a visual arrangement of the one real signal we have, no new
    /// data source.
    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 8
        let variance = (sin(Double(index) * 0.9) * 0.5) + 0.5
        let level = CGFloat(recorder.level)
        return base + (110 * level * CGFloat(variance))
    }
}
