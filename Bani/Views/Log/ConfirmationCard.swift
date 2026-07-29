import SwiftUI
import SwiftData
import Foundation
import UIKit

/// The Log flow's finishing move. Slides up after transcribe → parse.
/// Shows the parsed amount as the hero (large, rounded, monospaced digits),
/// currency, description, and context tag. Auto-saves after a short
/// countdown (circular ring) unless paused by a tap (→ inline edit of every
/// field), an app-background transition, or discarded via a downward swipe.
///
/// If the parser found no amount, the card opens directly in edit mode with
/// the raw transcript visible — it never invents a number.
struct ConfirmationCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    let transcript: String
    let context: TransactionContext
    let onComplete: () -> Void

    @State private var amountText: String
    @State private var currency: Currency
    @State private var descriptionText: String
    @State private var editingContext: TransactionContext
    @State private var isEditing: Bool

    @State private var countdownProgress: Double = 1.0
    @State private var remaining: Double = Self.autoSaveDelay
    @State private var isPausedByBackground = false
    @State private var isResolved = false
    @State private var dragOffset: CGFloat = 0

    private static let autoSaveDelay: Double = 2.0
    private static let tickInterval: Double = 0.05
    private static let discardDragThreshold: CGFloat = 100

    init(parsed: ParsedTransaction, transcript: String, context: TransactionContext, onComplete: @escaping () -> Void) {
        self.transcript = transcript
        self.context = context
        self.onComplete = onComplete
        _amountText = State(initialValue: parsed.amount.map { "\($0)" } ?? "")
        _currency = State(initialValue: parsed.currency)
        _descriptionText = State(initialValue: parsed.descriptionText)
        _editingContext = State(initialValue: context)
        // Never invent a number: no parsed amount → open directly in edit mode.
        _isEditing = State(initialValue: parsed.amount == nil)
    }

    private var canSave: Bool {
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return false }
        return amount > 0
    }

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(Color("BaniHairline"))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            if isEditing {
                editingForm
            } else {
                summary
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color("BaniSurface"))
                .shadow(color: Color("BaniInk").opacity(0.15), radius: 20, y: -4)
        )
        .padding(.horizontal, 12)
        .offset(y: max(0, dragOffset))
        .simultaneousGesture(dragGesture)
        .onTapGesture {
            if !isEditing { isEditing = true }
        }
        .task {
            await runCountdownLoop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            isPausedByBackground = newPhase != .active
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if isEditing {
            return "Editing transaction. Amount \(amountText.isEmpty ? "not set" : amountText) \(currency.displayCode), \(descriptionText.isEmpty ? "no description" : descriptionText), \(editingContext.label)."
        } else {
            return "Confirm transaction: \(amountText) \(currency.displayCode), \(descriptionText.isEmpty ? "no description" : descriptionText), \(editingContext.label). Auto-saving shortly. Tap to edit, swipe down to discard."
        }
    }

    // MARK: - Display (auto-save countdown state)

    private var summary: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                contextTag
                Spacer()
                countdownRing
            }
            Text(heroAmountText)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color("BaniInk"))
                .accessibilityIdentifier("confirmationCard.amountLabel")
            Text(descriptionText.isEmpty ? "No description" : descriptionText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
    }

    private var heroAmountText: String {
        "\(amountText) \(currency.symbol)"
    }

    private var contextTag: some View {
        Text(editingContext.label)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(editingContext.tagColorName).opacity(0.22))
            .foregroundStyle(Color(editingContext.tagColorName))
            .clipShape(Capsule())
    }

    private var countdownRing: some View {
        ZStack {
            Circle().stroke(Color("BaniHairline"), lineWidth: 3)
            Circle()
                .trim(from: 0, to: countdownProgress)
                .stroke(Color("BaniAccent"), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    // MARK: - Editing state (every field)

    private var editingForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !transcript.isEmpty {
                Text("“\(transcript)”")
                    .font(.system(.footnote, design: .rounded))
                    .italic()
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .accessibilityIdentifier("confirmationCard.transcriptLabel")
            }

            HStack {
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .accessibilityLabel("Amount")
                    .accessibilityIdentifier("confirmationCard.amountField")

                Picker("Currency", selection: $currency) {
                    ForEach(Currency.allCases, id: \.self) { c in
                        Text(c.displayCode).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .accessibilityIdentifier("confirmationCard.currencyToggle")
            }

            TextField("Description", text: $descriptionText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Description")
                .accessibilityIdentifier("confirmationCard.descriptionField")

            Picker("Context", selection: $editingContext) {
                ForEach(TransactionContext.allCases, id: \.self) { ctx in
                    Text(ctx.label).tag(ctx)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("confirmationCard.contextPicker")

            HStack(spacing: 12) {
                Button("Discard", role: .destructive) { discard() }
                    .accessibilityIdentifier("confirmationCard.discardButton")
                Spacer()
                Button("Save") { Task { await performSave() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BaniAccent"))
                    .disabled(!canSave)
                    .accessibilityIdentifier("confirmationCard.saveButton")
            }
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if value.translation.height > Self.discardDragThreshold {
                    discard()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Countdown

    private func runCountdownLoop() async {
        while remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            if Task.isCancelled { return }
            guard !isEditing, !isPausedByBackground else { continue }
            remaining -= Self.tickInterval
            countdownProgress = max(0, remaining / Self.autoSaveDelay)
        }
        await performSave()
    }

    // MARK: - Actions

    private func discard() {
        guard !isResolved else { return }
        isResolved = true
        onComplete()
    }

    @MainActor
    private func performSave() async {
        guard !isResolved else { return }
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")), amount > 0 else {
            // Guards against the auto-save timer firing on an unresolved
            // amount; drops into edit mode instead of ever inventing one.
            isEditing = true
            return
        }
        isResolved = true
        let finalParsed = ParsedTransaction(
            amount: amount,
            currency: currency,
            descriptionText: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            merchant: nil
        )
        let saved = saveVoiceTransaction(parsed: finalParsed, transcript: transcript, context: editingContext, into: modelContext)
        if saved != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        onComplete()
    }
}

/// Reusable voice-save routine shared by the auto-save countdown and the
/// manual "Save" action inside `ConfirmationCard`. Also the seam
/// `VoiceFlowIntegrationTests` drives directly (no UI, no real audio).
/// Never invents an amount: returns `nil` and inserts nothing when
/// `parsed.amount` is nil — callers are expected to have already resolved a
/// real amount (via parse or inline edit) before calling this.
@MainActor
@discardableResult
func saveVoiceTransaction(
    parsed: ParsedTransaction,
    transcript: String,
    context: TransactionContext,
    into modelContext: ModelContext
) -> Transaction? {
    guard let amount = parsed.amount else { return nil }
    let transaction = Transaction(
        amount: amount,
        currency: parsed.currency,
        context: context,
        descriptionText: parsed.descriptionText,
        merchant: parsed.merchant,
        rawTranscript: transcript,
        source: .voice
    )
    modelContext.insert(transaction)
    try? modelContext.save()
    return transaction
}
