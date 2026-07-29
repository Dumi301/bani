import SwiftUI
import SwiftData

/// Full-detail editor for an existing `Transaction`, presented as a sheet from
/// `FinancesView` on row tap. Edits are staged in local `@State` and only
/// written back to the model (then saved via `@Environment(\.modelContext)`)
/// when the user taps Save — Cancel discards without mutating the persisted object.
struct TransactionEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var customCategories: [CustomCategory]

    let transaction: Transaction

    @State private var amount: Decimal
    @State private var currency: Currency
    @State private var context: TransactionContext
    /// The unified category (preset OR custom, C3).
    @State private var categoryRef: CategoryRef?
    @State private var descriptionText: String
    @State private var merchant: String
    /// C3: the transaction's date+time, pre-filled (never blank) and editable.
    @State private var date: Date
    @State private var isCreatingCategory = false

    init(transaction: Transaction) {
        self.transaction = transaction
        _amount = State(initialValue: transaction.amount)
        _currency = State(initialValue: transaction.currency)
        _context = State(initialValue: transaction.context)
        _categoryRef = State(initialValue: transaction.categoryRef)
        _descriptionText = State(initialValue: transaction.descriptionText)
        _merchant = State(initialValue: transaction.merchant ?? "")
        _date = State(initialValue: transaction.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    HStack(spacing: 12) {
                        TextField("Amount", value: $amount, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .accessibilityIdentifier("editAmountField")

                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { currency in
                                Text(currency.displayCode).tag(currency)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("editCurrencyPicker")
                    }
                }

                Section("Details") {
                    TextField("Description", text: $descriptionText)
                    TextField("Merchant (optional)", text: $merchant)
                    // C3: editable, locale-aware date+time picker (pre-filled).
                    DatePicker("Date & time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("editDatePicker")
                }

                Section("Context") {
                    Picker("Context", selection: $context) {
                        ForEach(TransactionContext.allCases, id: \.self) { context in
                            Text(context.label).tag(context)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("editContextPicker")
                }

                Section("Category") {
                    CategoryChipPicker(
                        selection: $categoryRef,
                        customCategories: customCategories,
                        includeNone: true,
                        onCreateNew: { isCreatingCategory = true }
                    )
                    .accessibilityIdentifier("editCategoryPicker")
                }
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("editSaveButton")
                }
            }
            .sheet(isPresented: $isCreatingCategory) {
                NewCategorySheet { created in
                    categoryRef = .custom(created.id)
                }
            }
        }
    }

    private func save() {
        let categoryChanged = categoryRef != transaction.categoryRef
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)

        transaction.amount = amount
        transaction.currency = currency
        transaction.context = context
        transaction.categoryRef = categoryRef
        transaction.descriptionText = cleanDescription
        transaction.merchant = merchant.isEmpty ? nil : merchant
        transaction.date = date
        try? modelContext.save()

        // D2: a category correction here feeds the SAME learning path as the
        // confirmation card (C3) — one seam, presets and custom categories alike.
        if categoryChanged, let categoryRef {
            CategoryRuleStore.learn(
                correctedRef: categoryRef,
                description: cleanDescription,
                merchant: merchant.isEmpty ? nil : merchant,
                in: modelContext
            )
        }
        dismiss()
    }
}

#Preview {
    TransactionEditSheet(transaction: Transaction(
        amount: 52, currency: .ron, context: .personal, category: .fuel,
        descriptionText: "benzină", merchant: "OMV", source: .voice
    ))
}
