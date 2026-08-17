import SwiftUI
import SwiftData
import UIKit

/// Part B pickup — drains the App Group captures the share extension wrote, runs
/// the OCR ladder (images) / passes text through, and parses each into a pending
/// capture for the confirmation card. OCR is done OFF the main actor so a large
/// screenshot never blocks the Log tab.
enum SharePickup {
    struct Capture: Identifiable, Sendable {
        let id: UUID
        let parse: BankNotificationParse
        let rawText: String
    }

    static func drain() async -> [Capture] {
        await Task.detached(priority: .userInitiated) {
            SharedPayloadStore.drain().compactMap { drained -> Capture? in
                let text: String
                switch drained.payload.kind {
                case .text:
                    text = drained.payload.text ?? ""
                case .image:
                    guard let data = drained.imageData, let image = UIImage(data: data) else { return nil }
                    text = OCRService.recognize(image) ?? ""
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return Capture(id: UUID(), parse: BankNotificationParser.parse(trimmed), rawText: trimmed)
            }
        }.value
    }
}

/// The pre-filled confirmation card for a share-sheet capture (Part B). Amount,
/// merchant/description, direction and currency are pre-filled from
/// `BankNotificationParser`; the raw captured text is always shown. A parseable
/// capture opens ready to confirm; an unparseable one opens with the amount blank
/// and the OCR text visible (the silent-card-bail contract). Confirm writes an
/// `.autoLogged` transaction (`[share]` origin) and resolves it in the ledger
/// (badge everywhere, feeds TrustEngine); Discard drops it, saving nothing.
struct ShareCaptureCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var customCategories: [CustomCategory]
    /// v1.2a — projects for the Work-context project chip.
    @Query private var projects: [Project]
    @AppStorage("lastUsedProjectID") private var lastUsedProjectRaw: String = ""
    @State private var selectedProjectID: UUID?

    let capture: SharePickup.Capture
    let onResolve: () -> Void

    private var activeProjects: [ProjectSnapshot] { projects.filter { !$0.archived }.map(\.snapshot) }

    @State private var amountText: String
    @State private var currency: Currency
    @State private var descriptionText: String
    @State private var categoryRef: CategoryRef?
    @State private var editingContext: TransactionContext
    @State private var direction: TransactionDirection

    init(capture: SharePickup.Capture, onResolve: @escaping () -> Void) {
        self.capture = capture
        self.onResolve = onResolve
        let parse = capture.parse
        _amountText = State(initialValue: parse.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _currency = State(initialValue: parse.currency)
        _descriptionText = State(initialValue: parse.merchant ?? "")
        _categoryRef = State(initialValue: nil)
        _editingContext = State(initialValue: .personal)
        _direction = State(initialValue: parse.direction)
    }

    private var canSave: Bool {
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return false }
        return amount > 0
    }

    private var refBinding: Binding<CategoryRef?> {
        Binding(get: { categoryRef }, set: { categoryRef = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("shareCard.amountField")
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.displayCode).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                    TextField("Description", text: $descriptionText)
                        .accessibilityIdentifier("shareCard.descriptionField")
                }
                .listRowBackground(Palette.surface)

                Section {
                    CategoryChipPicker(selection: refBinding, customCategories: customCategories, onCreateNew: {})
                    Picker("Context", selection: $editingContext) {
                        ForEach(TransactionContext.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DirectionPicker(selection: $direction)
                    // v1.2a: project assignment, Work context only.
                    if editingContext == .work {
                        ProjectPickerRow(projects: activeProjects, selectedID: $selectedProjectID)
                            .accessibilityIdentifier("shareCard.projectPicker")
                    }
                }
                .listRowBackground(Palette.surface)

                Section {
                    Text(capture.rawText)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                        .accessibilityIdentifier("shareCard.rawText")
                } header: {
                    Text("share.card.rawText").foregroundStyle(Palette.secondaryInk)
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("share.card.title")
            .navigationBarTitleDisplayMode(.inline)
            // Never silently drop: the capture is resolved only via Save or Discard,
            // not a swipe-dismiss (which would also re-present the same item).
            .interactiveDismissDisabled()
            .onAppear {
                if categoryRef == nil {
                    categoryRef = CategoryRuleStore.guessRef(description: descriptionText, merchant: capture.parse.merchant, in: modelContext)
                }
                if selectedProjectID == nil { selectedProjectID = UUID(uuidString: lastUsedProjectRaw) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("autolog.discard", role: .destructive) {
                        onResolve()
                        dismiss()
                    }
                    .accessibilityIdentifier("shareCard.discard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("shareCard.save")
                }
            }
        }
    }

    private func save() {
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")), amount > 0 else { return }
        let tx = AutoLogWriter.logShared(
            amount: amount, currency: currency, descriptionText: descriptionText,
            merchant: capture.parse.merchant, direction: direction, rawText: capture.rawText,
            in: modelContext
        )
        if let categoryRef {
            tx.categoryRef = categoryRef
        }
        // v1.2a: Work captures carry the chosen project (clamped to an active one).
        if editingContext == .work,
           let projectID = activeProjects.first(where: { $0.id == selectedProjectID })?.id {
            tx.projectID = projectID
            lastUsedProjectRaw = projectID.uuidString
        }
        try? modelContext.save()
        // Resolve it in the ledger (marks it reviewed; feeds TrustEngine) — the card
        // WAS the confirmation, so it does not re-appear in the review chip.
        AutoLogReview.confirm(tx, in: modelContext)
        onResolve()
        dismiss()
    }
}
