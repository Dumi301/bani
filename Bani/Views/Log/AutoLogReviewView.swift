import SwiftUI
import SwiftData

/// The review surface for auto-logged payments (Part A). Reached from the Log
/// tab's "N auto-logged — review" chip. Lists the unreviewed auto-logged entries;
/// each offers one-tap Confirm / Edit / Discard. Every resolution writes exactly
/// one `DecisionRecord` (via `AutoLogReview`), feeding `TrustEngine` like a voice
/// card. Discard is a real delete with an Undo toast.
struct AutoLogReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    @Query private var customCategories: [CustomCategory]

    @State private var items: [Transaction] = []
    @State private var editing: Transaction?
    @State private var lastDiscarded: AutoLogReview.DiscardedSnapshot?
    @State private var showUndo = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Palette.canvas.ignoresSafeArea()

                if items.isEmpty {
                    ContentUnavailableView {
                        Label("autolog.review.empty", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("autoLogReview.empty")
                } else {
                    list
                }

                if showUndo { undoToast }
            }
            .navigationTitle("autolog.review.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("autolog.done") { dismiss() }
                        .accessibilityIdentifier("autoLogReview.done")
                }
            }
            .sheet(isPresented: editingBinding) {
                if let tx = editing {
                    AutoLogEditSheet(transaction: tx) { edit in
                        AutoLogReview.applyEdit(tx, to: edit, in: modelContext)
                        reload()
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    private var list: some View {
        List {
            ForEach(items, id: \.id) { tx in
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    TransactionRow(transaction: tx, customs: customCategories.lookup)
                    actionRow(for: tx)
                }
                .padding(.vertical, metrics.rowVInset)
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("autoLogReview.list")
    }

    private func actionRow(for tx: Transaction) -> some View {
        HStack(spacing: metrics.rowSpacing) {
            Button {
                AutoLogReview.confirm(tx, in: modelContext)
                reload()
            } label: {
                Label("autolog.confirm", systemImage: "hand.thumbsup.fill")
                    .font(.system(.subheadline).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tint(Palette.accent)
            .accessibilityIdentifier("autoLogReview.confirm")

            Button {
                editing = tx
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.system(.subheadline).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tint(Palette.ink)
            .accessibilityIdentifier("autoLogReview.edit")

            Button(role: .destructive) {
                lastDiscarded = AutoLogReview.discard(tx, in: modelContext)
                reload()
                withAnimation { showUndo = true }
            } label: {
                Label("autolog.discard", systemImage: "trash")
                    .font(.system(.subheadline).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("autoLogReview.discard")
        }
        .labelStyle(.titleAndIcon)
    }

    private var undoToast: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(Palette.secondaryInk)
            Text("autolog.discarded")
                .font(.system(.subheadline).weight(.medium))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Button("Undo") {
                if let lastDiscarded { AutoLogReview.restore(lastDiscarded, in: modelContext) }
                lastDiscarded = nil
                withAnimation { showUndo = false }
                reload()
            }
            .font(.system(.subheadline).weight(.semibold))
            .foregroundStyle(Palette.accent)
            .accessibilityIdentifier("autoLogReview.undo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .metalSurface(cornerRadius: Radius.plate, elevated: true)
        .padding(.horizontal, metrics.screenPadding)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: showUndo) {
            guard showUndo else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation { showUndo = false } }
        }
    }

    private func reload() {
        items = AutoLogReview.unreviewed(in: modelContext)
    }
}

/// Compact editor for one auto-logged entry — the same fields as the confirmation
/// card. Prefilled from the transaction; "Save" hands an `AutoLogReview.Edit` back
/// so the caller writes the corrected `DecisionRecord`.
private struct AutoLogEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var customCategories: [CustomCategory]
    /// v1.2a — projects for the correctable project field.
    @Query private var projects: [Project]

    let transaction: Transaction
    let onSave: (AutoLogReview.Edit) -> Void

    @State private var amountText: String
    @State private var currency: Currency
    @State private var descriptionText: String
    @State private var categoryRef: CategoryRef?
    @State private var editingContext: TransactionContext
    @State private var direction: TransactionDirection
    @State private var selectedProjectID: UUID?

    init(transaction: Transaction, onSave: @escaping (AutoLogReview.Edit) -> Void) {
        self.transaction = transaction
        self.onSave = onSave
        _amountText = State(initialValue: NSDecimalNumber(decimal: transaction.amount).stringValue)
        _currency = State(initialValue: transaction.currency)
        _descriptionText = State(initialValue: transaction.descriptionText)
        _categoryRef = State(initialValue: transaction.categoryRef)
        _editingContext = State(initialValue: transaction.context)
        _direction = State(initialValue: transaction.direction)
        _selectedProjectID = State(initialValue: transaction.projectID)
    }

    private var activeProjects: [ProjectSnapshot] { projects.filter { !$0.archived }.map(\.snapshot) }

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
                            .accessibilityIdentifier("autoLogEdit.amountField")
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.displayCode).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                    TextField("Description", text: $descriptionText)
                        .accessibilityIdentifier("autoLogEdit.descriptionField")
                }
                .listRowBackground(Palette.surface)

                Section {
                    CategoryChipPicker(
                        selection: refBinding,
                        customCategories: customCategories,
                        onCreateNew: {}
                    )
                    Picker("Context", selection: $editingContext) {
                        ForEach(TransactionContext.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DirectionPicker(selection: $direction)
                    // v1.2a: project is a correctable field on the review chip.
                    ProjectPickerRow(projects: activeProjects, selectedID: $selectedProjectID)
                        .accessibilityIdentifier("autoLogEdit.projectPicker")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) ?? transaction.amount
                        var edit = AutoLogReview.Edit(from: transaction)
                        edit.amount = amount
                        edit.currency = currency
                        edit.descriptionText = descriptionText
                        edit.categoryRef = categoryRef
                        edit.context = editingContext
                        edit.direction = direction
                        edit.projectID = selectedProjectID
                        onSave(edit)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("autoLogEdit.save")
                }
            }
        }
    }
}
