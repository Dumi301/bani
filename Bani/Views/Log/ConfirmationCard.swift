import SwiftUI
import SwiftData
import Foundation
import UIKit

/// The Log flow's finishing move — the app's ONLY quality gate, and the surface
/// the feedback ledger learns from (B). The card is a QUESTION; 👍/👎 are graded
/// answers; every answer writes exactly one `DecisionRecord`.
///   Q1 "Did I hear you right?" — amount + currency + description as parsed,
///      with the raw transcript in smaller secondary text underneath.
///   Q2 "Did I categorize right?" — the category GUESS as a chip (icon + label),
///      always pre-filled from the categorizer, falling back to Other.
///
/// 👍 saves immediately (confirmedExplicit). Letting the countdown finish saves
/// too (confirmedImplicit). 👎 stops the countdown and flips to edit mode; the
/// eventual save records `corrected` + which fields changed, or `discarded` if
/// abandoned. When the fired rule is TRUSTED (B4), the card auto-saves after 1 s
/// with a compact toast + Undo instead of asking. If the parser found no amount
/// (or transcription failed) the card opens directly in edit mode — it never
/// invents a number.
struct ConfirmationCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Custom categories (C2/C3) — resolve the guess chip and feed the picker.
    @Query private var customCategories: [CustomCategory]

    let transcript: String
    let context: TransactionContext
    let onComplete: () -> Void
    /// Non-nil when transcription failed or produced nothing usable. Forces
    /// edit mode and shows the error line; the card still never dismisses on
    /// its own (spec: "never silently drop").
    let errorMessage: String?
    /// Whether the shown context was pre-selected by a learned `ContextRule`
    /// (B3) — surfaced as a small "auto: <context>" note, correctable as always.
    let autoContextApplied: Bool
    /// The category rule that fired for the guess (B4) — the trust-scoring key.
    let firedRuleID: UUID?
    /// Whether that fired rule is TRUSTED right now → the compact auto-save flow.
    let trusted: Bool
    /// The refined transcript (A1 `cleanText`) the guess was made from, stored on
    /// the decision record for diagnostics.
    let refinedText: String

    // Baselines captured at init — the "question" the card asked, compared to the
    // final values at save time to derive `correctedFields` (B1/B3).
    private let baselineAmount: Decimal?
    private let baselineCurrency: Currency
    private let baselineDescription: String
    private let baselineRef: CategoryRef
    private let baselineContext: TransactionContext
    private let baselineDate: Date
    private let openedInEditMode: Bool

    @State private var amountText: String
    @State private var currency: Currency
    @State private var descriptionText: String
    @State private var editingContext: TransactionContext
    @State private var isEditing: Bool
    /// The transaction date+time (C1). Defaults to now; editable in edit mode so
    /// past expenses can be logged.
    @State private var date: Date

    /// The category guess (Q2) — ALWAYS a real category, never nil, so the chip
    /// is never a placeholder. Pre-filled from the categorizer (falls back to
    /// `.preset(.other)`); may be a preset OR a custom category (C3).
    @State private var categoryRef: CategoryRef
    /// Set once the user picks a category by hand — flips the save from
    /// "reinforce the rule that fired" to "learn this correction".
    @State private var categoryUserEdited: Bool = false
    /// The inline category picker (opened by tapping the chip in summary mode).
    @State private var isPickingCategory = false
    /// The "+ New category" creation sheet (C2).
    @State private var isCreatingCategory = false

    @State private var countdownProgress: Double = 1.0
    @State private var remaining: Double = ConfirmationCard.defaultAutoSaveDelay
    @State private var isPausedByBackground = false
    /// True while a finger is down on the card (summary mode) — pauses the
    /// countdown the instant the surface is touched, anywhere.
    @State private var isTouching = false
    @State private var isResolved = false
    @State private var dragOffset: CGFloat = 0

    // Trusted-flow state (B4): after a trusted auto-save, the card stays as a
    // "Saved — … ✓" toast with an Undo for 5 s before dismissing.
    @State private var showTrustedToast = false
    @State private var savedRecord: DecisionRecord?
    @State private var savedTransactionID: UUID?
    /// When the card appeared — used for the decision record's `latencySeconds`.
    @State private var appearedAt = Date()

    /// Auto-save countdown length. Read from the "Confirmation time" setting
    /// (`confirmationDuration`, 2–8 s); defaults to 4 s.
    @AppStorage("confirmationDuration") private var storedDuration: Double = ConfirmationCard.defaultAutoSaveDelay

    static let defaultAutoSaveDelay: Double = 4.0
    static let minAutoSaveDelay: Double = 2.0
    static let maxAutoSaveDelay: Double = 8.0
    /// A trusted rule fires the compact auto-save after just 1 s (B4).
    static let trustedAutoSaveDelay: Double = 1.0
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

    /// The compact trusted auto-save applies only when the card is a normal
    /// summary (has an amount, no error) AND the fired rule is trusted.
    private var isTrustedSummary: Bool { trusted && !openedInEditMode }

    /// How long the countdown runs: 1 s for the trusted compact flow, else the
    /// configured 2–8 s.
    private var effectiveAutoSaveDelay: Double { isTrustedSummary ? Self.trustedAutoSaveDelay : autoSaveDelay }

    /// The reason the countdown-expiry save records (trusted → still implicit).
    private enum SaveReason { case explicitThumbsUp, implicitExpiry, editedSave, trustedImplicit }

    init(
        parsed: ParsedTransaction,
        transcript: String,
        errorMessage: String? = nil,
        context: TransactionContext,
        categoryRef: CategoryRef = .preset(.other),
        autoContextApplied: Bool = false,
        firedRuleID: UUID? = nil,
        trusted: Bool = false,
        refinedText: String = "",
        onComplete: @escaping () -> Void
    ) {
        self.transcript = transcript
        self.context = context
        self.onComplete = onComplete
        self.errorMessage = errorMessage
        self.autoContextApplied = autoContextApplied
        self.firedRuleID = firedRuleID
        self.trusted = trusted
        self.refinedText = refinedText

        let now = Date()
        self.baselineAmount = parsed.amount
        self.baselineCurrency = parsed.currency
        self.baselineDescription = parsed.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baselineRef = categoryRef
        self.baselineContext = context
        self.baselineDate = now
        self.openedInEditMode = VoicePipelineResult.shouldOpenInEditMode(
            parsedAmount: parsed.amount,
            errorMessage: errorMessage
        )

        _amountText = State(initialValue: parsed.amount.map { "\($0)" } ?? "")
        _currency = State(initialValue: parsed.currency)
        _descriptionText = State(initialValue: parsed.descriptionText)
        _editingContext = State(initialValue: context)
        _categoryRef = State(initialValue: categoryRef)
        _date = State(initialValue: now)
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

    // MARK: - Category helpers (preset + custom, C3)

    private var customLookup: CustomCategoryLookup { customCategories.lookup }
    private var categoryStyleValue: CategoryStyle { categoryStyle(categoryRef, customs: customLookup) }
    private var categoryLabel: String { categoryStyleValue.label }
    private var noDescriptionText: String { String(localized: "confirm.noDescription") }

    /// The binding the chip picker drives — any hand pick flags the save to learn.
    private var refBinding: Binding<CategoryRef?> {
        Binding(
            get: { categoryRef },
            set: { newValue in
                if let newValue {
                    categoryRef = newValue
                    categoryUserEdited = true
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(Color("BaniHairline"))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            if showTrustedToast {
                trustedToast
            } else if isEditing {
                editingForm
            } else if isTrustedSummary {
                trustedConfirming
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
            if !isEditing && !showTrustedToast { isEditing = true }
        }
        .task {
            await runCountdownLoop()
        }
        .task(id: showTrustedToast) {
            await autoDismissTrustedToast()
        }
        .onChange(of: scenePhase) { _, newPhase in
            isPausedByBackground = newPhase != .active
        }
        .onChange(of: descriptionText) { _, _ in
            // Keep the guessed chip truthful as the description is edited — but
            // only until the user has taken over the category themselves.
            if !categoryUserEdited {
                categoryRef = CategoryRuleStore.guessRef(description: descriptionText, in: modelContext)
            }
        }
        .sheet(isPresented: $isCreatingCategory) {
            NewCategorySheet { created in
                categoryRef = .custom(created.id)
                categoryUserEdited = true
                isPickingCategory = false
            }
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let desc = descriptionText.isEmpty ? noDescriptionText : descriptionText
        if isEditing {
            let amount = amountText.isEmpty ? String(localized: "confirm.a11y.amountNotSet") : amountText
            return String(localized: "confirm.a11y.editing \(amount) \(currency.displayCode) \(desc) \(categoryLabel) \(editingContext.label)")
        } else {
            return String(localized: "confirm.a11y.summary \(amountText) \(currency.displayCode) \(desc) \(categoryLabel) \(editingContext.label)")
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
                if autoContextApplied { autoContextNote }
                Spacer()
            }

            Text(descriptionText.isEmpty ? noDescriptionText : descriptionText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Color("BaniSecondaryInk"))

            dateLine

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

            feedbackRow

            if isPickingCategory {
                categoryPresetPicker
            }
        }
    }

    private var heroAmountText: String {
        "\(amountText) \(currency.symbol)"
    }

    /// Compact date+time line (C1) — locale-aware, so an RO device reads RO order.
    private var dateLine: some View {
        Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(Color("BaniSecondaryInk"))
            .accessibilityIdentifier("confirmationCard.dateLabel")
    }

    /// The 👍/👎 row (B2): big tap targets, accent for 👍. 👍 saves immediately;
    /// 👎 stops the countdown and opens edit mode to correct.
    private var feedbackRow: some View {
        HStack(spacing: 16) {
            Button {
                Task { await performSave(reason: .explicitThumbsUp) }
            } label: {
                Image(systemName: "hand.thumbsup.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color("BaniAccent"))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color("BaniAccent").opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("confirmationCard.thumbsUp")
            .accessibilityLabel("Looks right — save now")

            Button {
                thumbsDown()
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.system(size: 26))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color("BaniCanvas"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("confirmationCard.thumbsDown")
            .accessibilityLabel("Not right — edit before saving")
        }
        .padding(.top, 2)
    }

    /// Q2 — the category guess as a tappable chip (icon + label). Tapping it opens
    /// the inline preset picker (and pauses the countdown).
    private var categoryChip: some View {
        let style = categoryStyleValue
        return Button {
            isPickingCategory.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: style.systemImage)
                Text(style.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(style.color.opacity(0.16), in: Capsule())
            .foregroundStyle(style.color)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("confirmationCard.categoryChip")
        .accessibilityLabel("Category \(style.label). Tap to change.")
    }

    /// Small "auto: <context>" note (B3) shown when the context was pre-selected
    /// by a learned rule.
    private var autoContextNote: some View {
        Text("auto: \(editingContext.label)")
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(Color(editingContext.tagColorName))
            .accessibilityIdentifier("confirmationCard.autoContextNote")
    }

    /// The inline category picker — presets + custom categories + "+ New" (C2).
    /// Shares `CategoryChipPicker` with the edit sheet so both learn identically.
    private var categoryPresetPicker: some View {
        CategoryChipPicker(
            selection: refBinding,
            customCategories: customCategories,
            onCreateNew: { isCreatingCategory = true }
        )
        .accessibilityIdentifier("confirmationCard.categoryPicker")
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

    // MARK: - Trusted compact flow (B4)

    /// The compact "trusted" summary shown for the 1 s auto-save window — no
    /// 👍/👎, just the essentials + the ring. Tapping anywhere still opens edit.
    private var trustedConfirming: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heroAmountText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color("BaniInk"))
                Text("\(descriptionText.isEmpty ? noDescriptionText : descriptionText) · \(categoryLabel)")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .lineLimit(1)
            }
            Spacer()
            countdownRing
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trusted — auto-saving \(amountText) \(currency.displayCode), \(descriptionText.isEmpty ? noDescriptionText : descriptionText), \(categoryLabel). Tap to edit.")
        .accessibilityIdentifier("confirmationCard.trustedConfirming")
    }

    /// The post-save toast after a trusted auto-save: "Saved — … ✓" + Undo (5 s).
    private var trustedToast: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color("BaniAccent"))
            Text("Saved — \(descriptionText.isEmpty ? categoryLabel : descriptionText), \(categoryLabel) ✓")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(Color("BaniInk"))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Undo") { undoTrustedSave() }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color("BaniAccent"))
                .accessibilityIdentifier("confirmationCard.trustedUndo")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("confirmationCard.trustedToast")
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

            // Category is editable here too — same learning seam as the chip (C2).
            VStack(alignment: .leading, spacing: 6) {
                Text("Category")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                CategoryChipPicker(
                    selection: refBinding,
                    customCategories: customCategories,
                    onCreateNew: { isCreatingCategory = true }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("confirmationCard.categoryEditPicker")

            Picker("Context", selection: $editingContext) {
                ForEach(TransactionContext.allCases, id: \.self) { ctx in
                    Text(ctx.label).tag(ctx)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("confirmationCard.contextPicker")

            // C1: date+time is editable so past expenses can be logged.
            DatePicker(
                "Date & time",
                selection: $date,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.system(.subheadline, design: .rounded))
            .accessibilityIdentifier("confirmationCard.datePicker")

            HStack(spacing: 12) {
                Button("Discard", role: .destructive) { discard() }
                    .accessibilityIdentifier("confirmationCard.discardButton")
                Spacer()
                Button("Save") { Task { await performSave(reason: .editedSave) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BaniAccent"))
                    .disabled(!canSave)
                    .accessibilityIdentifier("confirmationCard.saveButton")
            }
        }
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
        let delay = effectiveAutoSaveDelay
        remaining = delay
        countdownProgress = 1.0
        while remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            if Task.isCancelled { return }
            if isResolved || showTrustedToast { return }
            guard Self.shouldRunCountdown(
                isEditing: isEditing,
                isPickingCategory: isPickingCategory,
                isPausedByBackground: isPausedByBackground,
                isTouching: isTouching
            ) else { continue }
            remaining -= Self.tickInterval
            countdownProgress = max(0, remaining / delay)
        }
        await performSave(reason: isTrustedSummary ? .trustedImplicit : .implicitExpiry)
    }

    // MARK: - Actions

    private func thumbsDown() {
        guard !isResolved else { return }
        isTouching = false
        isEditing = true
    }

    private func discard() {
        guard !isResolved else { return }
        isResolved = true
        // Every card resolution writes exactly one record (B1) — a discard is a
        // resolution too (likely a hallucination; a refiner-quality datapoint).
        DecisionLedger.record(
            outcome: .discarded,
            transactionID: nil,
            guessedCategory: baselineRef.presetValue,
            guessedContext: baselineContext,
            firedRuleID: firedRuleID,
            refinedText: refinedText,
            correctedFields: [],
            latencySeconds: max(0, Date().timeIntervalSince(appearedAt)),
            in: modelContext
        )
        onComplete()
    }

    @MainActor
    private func performSave(reason: SaveReason) async {
        guard !isResolved else { return }
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")), amount > 0 else {
            // Guards against the auto-save timer firing on an unresolved
            // amount; drops into edit mode instead of ever inventing one.
            isEditing = true
            return
        }
        isResolved = true
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = computeCorrectedFields(finalAmount: amount, finalDescription: cleanDescription)
        let outcome = resolveOutcome(reason: reason, fields: fields)
        let finalRef = resolveCategoryRefForSave(description: cleanDescription)

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
            categoryRef: finalRef,
            date: date,
            into: modelContext
        )

        // B3: accrue a context confirmation on every save (a context correction is
        // just a save under the corrected context) …
        ContextRuleStore.record(finalContext: editingContext, description: cleanDescription, in: modelContext)
        // … and remember a description rewrite so a recurring transcript reuses it.
        if fields.contains(.description) {
            CorrectionMemoryStore.remember(rawTranscript: transcript, correctedDescription: cleanDescription, in: modelContext)
        }

        // B1: exactly one ledger record for this resolution.
        let record = DecisionLedger.record(
            outcome: outcome,
            transactionID: saved?.id,
            guessedCategory: baselineRef.presetValue,
            guessedContext: baselineContext,
            firedRuleID: firedRuleID,
            refinedText: refinedText,
            correctedFields: fields,
            latencySeconds: max(0, Date().timeIntervalSince(appearedAt)),
            in: modelContext
        )

        if saved != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        // Trusted auto-save → keep the card as a "Saved — … ✓" toast with Undo for
        // 5 s instead of dismissing immediately (B4). The `.task(id:)` on the body
        // handles the 5 s dismissal (auto-cancelled if the user taps Undo first).
        if reason == .trustedImplicit, let saved {
            savedRecord = record
            savedTransactionID = saved.id
            withAnimation { showTrustedToast = true }
            return
        }

        onComplete()
    }

    /// The 5 s auto-dismiss for the trusted-save toast. Driven by `.task(id:)`, so
    /// it re-runs when `showTrustedToast` flips and is cancelled when the user
    /// undoes (flipping it back to `false`).
    private func autoDismissTrustedToast() async {
        guard showTrustedToast else { return }
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled && showTrustedToast {
            onComplete()
        }
    }

    /// Undo a trusted auto-save (B4): delete the saved transaction and flip the
    /// decision record to a miss, so trust is correctly lost.
    private func undoTrustedSave() {
        guard showTrustedToast else { return }
        showTrustedToast = false
        if let txID = savedTransactionID {
            let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == txID })
            if let tx = (try? modelContext.fetch(descriptor))?.first {
                modelContext.delete(tx)
                try? modelContext.save()
            }
        }
        if let savedRecord {
            DecisionLedger.markTrustedSaveUndone(savedRecord, in: modelContext)
        }
        onComplete()
    }

    /// Which fields the user changed versus the guess the card asked with (B1).
    private func computeCorrectedFields(finalAmount: Decimal, finalDescription: String) -> CorrectedFields {
        var fields: CorrectedFields = []
        let amountChanged: Bool = {
            guard let base = baselineAmount else { return true }  // guessed no amount → typing one is a correction
            return base != finalAmount
        }()
        if amountChanged { fields.insert(.amount) }
        if baselineCurrency != currency { fields.insert(.currency) }
        if baselineDescription != finalDescription { fields.insert(.description) }
        if baselineRef != categoryRef { fields.insert(.category) }
        if baselineContext != editingContext { fields.insert(.context) }
        if !Calendar.current.isDate(date, equalTo: baselineDate, toGranularity: .minute) { fields.insert(.date) }
        return fields
    }

    private func resolveOutcome(reason: SaveReason, fields: CorrectedFields) -> DecisionOutcome {
        switch reason {
        case .explicitThumbsUp:
            return .confirmedExplicit
        case .implicitExpiry, .trustedImplicit:
            return .confirmedImplicit
        case .editedSave:
            // A save from edit mode with no changed field is still a confirmation.
            return fields.isEmpty ? .confirmedExplicit : .corrected
        }
    }

    /// Resolves the category to persist and feeds the learning seam:
    /// a hand-edited category is learned; an unedited one re-runs the categorizer
    /// at save time and reinforces the rule that fired.
    @MainActor
    private func resolveCategoryRefForSave(description: String) -> CategoryRef {
        if categoryUserEdited {
            CategoryRuleStore.learn(correctedRef: categoryRef, description: description, in: modelContext)
            return categoryRef
        }
        if let match = CategoryRuleStore.bestMatch(description: description, in: modelContext) {
            CategoryRuleStore.reinforce(keyword: match.keyword, origin: match.origin, in: modelContext)
            return match.ref
        }
        return .preset(.other)
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
    categoryRef: CategoryRef? = nil,
    date: Date = .now,
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
        date: date,
        rawTranscript: transcript,
        source: .voice
    )
    // A custom-aware ref (C3) overrides the preset `category` param when given.
    if let categoryRef {
        transaction.categoryRef = categoryRef
    }
    modelContext.insert(transaction)
    try? modelContext.save()
    return transaction
}
