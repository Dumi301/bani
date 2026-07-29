import SwiftUI
import SwiftData
import Foundation
import UIKit

/// The Log flow's finishing move — the app's ONLY quality gate. It implicitly
/// asks exactly two questions, both answered pre-filled, never blank:
///   Q1 "Did I hear you right?" — amount + currency + description as parsed,
///      with the raw transcript in smaller secondary text underneath.
///   Q2 "Did I categorize right?" — the category GUESS as a chip (icon + label),
///      always pre-filled from the categorizer, falling back to Other.
///
/// Letting the countdown finish = yes to both. Editing anything = the correction
/// that teaches the memory (a learned `CategoryRule`). A tap anywhere pauses the
/// countdown; a downward swipe discards. If the parser found no amount (or
/// transcription failed) the card opens directly in edit mode — it never invents
/// a number.
struct ConfirmationCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    let transcript: String
    let context: TransactionContext
    let onComplete: () -> Void
    /// Non-nil when transcription failed or produced nothing usable. Forces
    /// edit mode and shows the error line; the card still never dismisses on
    /// its own (spec: "never silently drop").
    let errorMessage: String?

    @State private var amountText: String
    @State private var currency: Currency
    @State private var descriptionText: String
    @State private var editingContext: TransactionContext
    @State private var isEditing: Bool

    /// The category guess (Q2) — ALWAYS a real category, never nil, so the chip
    /// is never a placeholder. Pre-filled from the categorizer (falls back to
    /// `.other`).
    @State private var category: TransactionCategory
    /// Set once the user picks a category by hand — flips the save from
    /// "reinforce the rule that fired" to "learn this correction".
    @State private var categoryUserEdited: Bool = false
    /// The inline preset picker (opened by tapping the chip in summary mode).
    @State private var isPickingCategory = false

    @State private var countdownProgress: Double = 1.0
    @State private var remaining: Double = ConfirmationCard.defaultAutoSaveDelay
    @State private var isPausedByBackground = false
    /// True while a finger is down on the card (summary mode) — pauses the
    /// countdown the instant the surface is touched, anywhere.
    @State private var isTouching = false
    @State private var isResolved = false
    @State private var dragOffset: CGFloat = 0

    /// Auto-save countdown length. Read from the "Confirmation time" setting
    /// (`confirmationDuration`, 2–8 s); defaults to 4 s.
    @AppStorage("confirmationDuration") private var storedDuration: Double = ConfirmationCard.defaultAutoSaveDelay

    static let defaultAutoSaveDelay: Double = 4.0
    static let minAutoSaveDelay: Double = 2.0
    static let maxAutoSaveDelay: Double = 8.0
    private static let tickInterval: Double = 0.05
    private static let discardDragThreshold: CGFloat = 100

    /// Clamps a stored duration into the allowed 2–8 s range; `0`/unset → default.
    static func resolvedAutoSaveDelay(_ stored: Double) -> Double {
        guard stored > 0 else { return defaultAutoSaveDelay }
        return min(maxAutoSaveDelay, max(minAutoSaveDelay, stored))
    }

    /// Pure predicate for whether the countdown should be ticking — exposed for
    /// unit tests (B4). Any of edit mode, an open category picker, backgrounding,
    /// or an active touch pauses it.
    static func shouldRunCountdown(isEditing: Bool, isPickingCategory: Bool, isPausedByBackground: Bool, isTouching: Bool) -> Bool {
        !isEditing && !isPickingCategory && !isPausedByBackground && !isTouching
    }

    private var autoSaveDelay: Double { Self.resolvedAutoSaveDelay(storedDuration) }

    init(
        parsed: ParsedTransaction,
        transcript: String,
        errorMessage: String? = nil,
        context: TransactionContext,
        category: TransactionCategory = .other,
        onComplete: @escaping () -> Void
    ) {
        self.transcript = transcript
        self.context = context
        self.onComplete = onComplete
        self.errorMessage = errorMessage
        _amountText = State(initialValue: parsed.amount.map { "\($0)" } ?? "")
        _currency = State(initialValue: parsed.currency)
        _descriptionText = State(initialValue: parsed.descriptionText)
        _editingContext = State(initialValue: context)
        _category = State(initialValue: category)
        // Never invent a number, never hide a failure: no parsed amount OR a
        // transcription error → open directly in edit mode. Shared derivation
        // so the view and the A2 unit tests can never drift.
        _isEditing = State(initialValue: VoicePipelineResult.shouldOpenInEditMode(
            parsedAmount: parsed.amount,
            errorMessage: errorMessage
        ))
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
        .simultaneousGesture(cardGesture)
        .onTapGesture {
            if !isEditing { isEditing = true }
        }
        .task {
            await runCountdownLoop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            isPausedByBackground = newPhase != .active
        }
        .onChange(of: descriptionText) { _, _ in
            // Keep the guessed chip truthful as the description is edited — but
            // only until the user has taken over the category themselves.
            if !categoryUserEdited {
                category = CategoryRuleStore.guess(description: descriptionText, in: modelContext)
            }
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if isEditing {
            return "Editing transaction. Amount \(amountText.isEmpty ? "not set" : amountText) \(currency.displayCode), \(descriptionText.isEmpty ? "no description" : descriptionText), \(category.label), \(editingContext.label)."
        } else {
            return "Confirm transaction: \(amountText) \(currency.displayCode), \(descriptionText.isEmpty ? "no description" : descriptionText), \(category.label), \(editingContext.label). Auto-saving shortly. Tap to edit, swipe down to discard."
        }
    }

    // MARK: - Display (auto-save countdown state)

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                countdownRing
            }

            // B3 order: amount hero → chip + context → description → transcript.
            Text(heroAmountText)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color("BaniInk"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("confirmationCard.amountLabel")

            HStack(spacing: 8) {
                categoryChip
                contextTag
                Spacer()
            }

            Text(descriptionText.isEmpty ? "No description" : descriptionText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Color("BaniSecondaryInk"))

            if !transcript.isEmpty {
                // Raw transcript, one line, truncated — so a mishear is spottable
                // at a glance without cluttering the card (Q1).
                Text("“\(transcript)”")
                    .font(.system(.footnote, design: .rounded))
                    .italic()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color("BaniSecondaryInk").opacity(0.8))
                    .accessibilityIdentifier("confirmationCard.transcriptLabel")
            }

            if isPickingCategory {
                categoryPresetPicker
            }
        }
    }

    private var heroAmountText: String {
        "\(amountText) \(currency.symbol)"
    }

    /// Q2 — the category guess as a tappable chip (icon + label). Tapping it opens
    /// the inline preset picker (and pauses the countdown).
    private var categoryChip: some View {
        Button {
            isPickingCategory.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: category.systemImage)
                Text(category.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color("BaniAccent").opacity(0.14), in: Capsule())
            .foregroundStyle(Color("BaniAccent"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("confirmationCard.categoryChip")
        .accessibilityLabel("Category \(category.label). Tap to change.")
    }

    /// Horizontally scrollable preset chips — the inline category picker.
    private var categoryPresetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TransactionCategory.allCases, id: \.self) { preset in
                    Button {
                        selectCategory(preset)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: preset.systemImage)
                            Text(preset.label)
                        }
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            preset == category ? Color("BaniAccent").opacity(0.22) : Color("BaniCanvas"),
                            in: Capsule()
                        )
                        .foregroundStyle(preset == category ? Color("BaniAccent") : Color("BaniInk"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("confirmationCard.categoryPicker")
    }

    private func selectCategory(_ preset: TransactionCategory) {
        category = preset
        categoryUserEdited = true
        isPickingCategory = false
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
            if let errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(VoicePipelineResult.errorHeadline)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color("BaniTagWork"))
                    // Raw underlying message, kept accessible for device debugging.
                    Text(errorMessage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(VoicePipelineResult.errorHeadline) \(errorMessage)")
                .accessibilityIdentifier("confirmationCard.errorLabel")
            }

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

            // Category is editable here too — same learning seam as the chip.
            Picker("Category", selection: categoryBinding) {
                ForEach(TransactionCategory.allCases, id: \.self) { preset in
                    Label(preset.label, systemImage: preset.systemImage).tag(preset)
                }
            }
            .accessibilityIdentifier("confirmationCard.categoryEditPicker")

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

    /// Category binding that records a hand edit (so the save learns it) whenever
    /// the picker changes the value — programmatic guess updates set `category`
    /// directly and are NOT flagged as edits.
    private var categoryBinding: Binding<TransactionCategory> {
        Binding(
            get: { category },
            set: { newValue in
                category = newValue
                categoryUserEdited = true
            }
        )
    }

    // MARK: - Gestures

    /// One drag gesture for the whole card. In summary mode it uses a zero
    /// minimum distance so the countdown pauses the instant the surface is
    /// touched anywhere; in edit mode it keeps a normal threshold (so it doesn't
    /// fight the text fields) and only handles swipe-to-discard.
    private var cardGesture: some Gesture {
        DragGesture(minimumDistance: isEditing ? 10 : 0)
            .onChanged { value in
                if !isEditing { isTouching = true }
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if value.translation.height > Self.discardDragThreshold {
                    discard()
                } else {
                    isTouching = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Countdown

    private func runCountdownLoop() async {
        remaining = autoSaveDelay
        countdownProgress = 1.0
        while remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            if Task.isCancelled { return }
            guard Self.shouldRunCountdown(
                isEditing: isEditing,
                isPickingCategory: isPickingCategory,
                isPausedByBackground: isPausedByBackground,
                isTouching: isTouching
            ) else { continue }
            remaining -= Self.tickInterval
            countdownProgress = max(0, remaining / autoSaveDelay)
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
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = resolveCategoryForSave(description: cleanDescription)

        let finalParsed = ParsedTransaction(
            amount: amount,
            currency: currency,
            descriptionText: cleanDescription,
            merchant: nil
        )
        let saved = saveVoiceTransaction(
            parsed: finalParsed,
            transcript: transcript,
            context: editingContext,
            category: finalCategory,
            into: modelContext
        )
        if saved != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        onComplete()
    }

    /// Resolves the category to persist and feeds the learning seam (C4):
    /// a hand-edited category is learned; an unedited one re-runs the categorizer
    /// at save time and reinforces the rule that fired.
    @MainActor
    private func resolveCategoryForSave(description: String) -> TransactionCategory {
        if categoryUserEdited {
            CategoryRuleStore.learn(correctedCategory: category, description: description, in: modelContext)
            return category
        }
        if let match = CategoryRuleStore.bestMatch(description: description, in: modelContext) {
            CategoryRuleStore.reinforce(keyword: match.keyword, origin: match.origin, in: modelContext)
            return match.category
        }
        return .other
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
    category: TransactionCategory? = nil,
    into modelContext: ModelContext
) -> Transaction? {
    guard let amount = parsed.amount else { return nil }
    let transaction = Transaction(
        amount: amount,
        currency: parsed.currency,
        context: context,
        category: category,
        descriptionText: parsed.descriptionText,
        merchant: parsed.merchant,
        rawTranscript: transcript,
        source: .voice
    )
    modelContext.insert(transaction)
    try? modelContext.save()
    return transaction
}
