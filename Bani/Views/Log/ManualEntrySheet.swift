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
    /// v1.2a — Work-context project assignment (smart-default: last-used project).
    @Query private var projects: [Project]
    @AppStorage("lastUsedProjectID") private var lastUsedProjectRaw: String = ""
    @State private var selectedProjectID: UUID?
    /// v1.3 — the other party (People registry, B3), optional everywhere.
    @State private var counterparty = ""
    @Query private var people: [Person]
    @Query private var allTransactions: [Transaction]
    @Query private var allScheduledItems: [ScheduledItem]

    private var activeProjects: [ProjectSnapshot] { projects.filter { !$0.archived }.map(\.snapshot) }
    private var registeredPeopleNames: [String] { people.map(\.name) }
    private var counterpartySuggestions: [String] {
        PersonStore.historicalCounterparties(transactions: allTransactions, scheduledItems: allScheduledItems)
    }

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

                    // v1.3 — optional counterparty with People-registry autocomplete (B3).
                    PersonCounterpartyField(text: $counterparty, people: registeredPeopleNames, historicalCounterparties: counterpartySuggestions)
                        .accessibilityIdentifier("manualEntry.counterpartyField")

                    // v1.2a: project assignment, Work context only.
                    if context == .work {
                        ProjectPickerRow(projects: activeProjects, selectedID: $selectedProjectID)
                            .accessibilityIdentifier("manualEntry.projectPicker")
                    }
                } header: {
                    Text("Details")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Color("BaniCanvas"))
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if selectedProjectID == nil { selectedProjectID = UUID(uuidString: lastUsedProjectRaw) }
            }
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

        // v1.2a: Work entries carry the chosen project (clamped to an active one);
        // Personal never does. Remember the last-used project for next time.
        let projectID: UUID? = (context == .work)
            ? activeProjects.first(where: { $0.id == selectedProjectID })?.id
            : nil
        let cleanCounterparty = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        let transaction = Transaction(
            amount: amount,
            currency: currency,
            context: context,
            category: category,
            descriptionText: cleanDescription,
            date: date,
            rawTranscript: nil,
            source: .manual,
            direction: direction,
            counterparty: cleanCounterparty.isEmpty ? nil : cleanCounterparty,
            projectID: projectID
        )
        modelContext.insert(transaction)
        try? modelContext.save()
        // P8 — never silently double-count: flag (never drop) a cross-source
        // possible duplicate for the review surface.
        DedupService.flagIfDuplicate(transaction, in: modelContext)
        if let projectID { lastUsedProjectRaw = projectID.uuidString }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
