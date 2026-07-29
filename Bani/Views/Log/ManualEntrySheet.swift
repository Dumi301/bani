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
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .accessibilityLabel("Amount")
                            .accessibilityIdentifier("manualEntry.amountField")
                        Text(currency.symbol)
                            .font(.system(.title2, design: .rounded))
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
                } header: {
                    Text("Details")
                }
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
        let transaction = Transaction(
            amount: amount,
            currency: currency,
            context: context,
            descriptionText: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            rawTranscript: nil,
            source: .manual
        )
        modelContext.insert(transaction)
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
