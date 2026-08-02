import SwiftUI
import SwiftData
import UIKit

/// Manual entry path reachable from `LogView`'s keyboard icon. Amount pad,
/// currency toggle (RON/EUR), description, context. **Zero Whisper
/// dependency** — this is the path verified with the Whisper model absent
/// (see `BaniUITests/ManualEntryUITests.swift`). Saves with
/// `source: .manual`, `rawTranscript: nil`.
struct ManualEntrySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var currency: Currency = .ron
    @State private var descriptionText = ""
    @State private var context: TransactionContext = .personal
    /// A3 — default expense (zero new friction), editable for income/neutral.
    @State private var direction: TransactionDirection = .expense
    /// C2: date+time for the manual entry, default now, editable for logging past
    /// expenses.
    @State private var date = Date()

    private var parsedAmount: Decimal? {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: "."))
    }

    private var canSave: Bool {
        guard let amount = parsedAmount else { return false }
        return amount > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(Typography.amount(.largeTitle))
                            .monospacedDigit()
                            .accessibilityLabel("Amount")
                            .accessibilityIdentifier("manualEntry.amountField")
                        Text(currency.symbol)
                            .font(.system(.title2))
                            .foregroundStyle(Color("BaniSecondaryInk"))
                    }

                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases, id: \.self) { c in
                            Text(c.displayCode).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("manualEntry.currencyToggle")
                } header: {
                    Text("Amount")
                }
                .listRowBackground(Palette.surface)

                Section {
                    TextField("Description", text: $descriptionText)
                        .accessibilityLabel("Description")
                        .accessibilityIdentifier("manualEntry.descriptionField")

                    Picker("Context", selection: $context) {
                        ForEach(TransactionContext.allCases, id: \.self) { ctx in
                            Text(ctx.label).tag(ctx)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("manualEntry.contextPicker")

                    // A3: direction (expense default), editable for income/neutral.
                    DirectionPicker(selection: $direction)
                        .accessibilityIdentifier("manualEntry.directionPicker")

                    // C2: locale-aware date+time picker, pre-filled with now.
                    DatePicker("Date & time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("manualEntry.datePicker")
                } header: {
                    Text("Details")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Color("BaniCanvas"))
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("manualEntry.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("manualEntry.saveButton")
                }
            }
        }
    }

    private func save() {
        guard let amount = parsedAmount, amount > 0 else { return }
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)

        // C3: manual saves get a category guess too (no picker here — the guess
        // runs at save time). Reinforce the rule that fired; Other if none.
        let category: TransactionCategory
        if let match = CategoryRuleStore.bestMatch(description: cleanDescription, in: modelContext) {
            CategoryRuleStore.reinforce(keyword: match.keyword, origin: match.origin, in: modelContext)
            category = match.category
        } else {
            category = .other
        }

        let transaction = Transaction(
            amount: amount,
            currency: currency,
            context: context,
            category: category,
            descriptionText: cleanDescription,
            date: date,
            rawTranscript: nil,
            source: .manual,
            direction: direction
        )
        modelContext.insert(transaction)
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
