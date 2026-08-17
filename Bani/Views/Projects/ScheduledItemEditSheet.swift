import SwiftUI
import SwiftData

/// Add or edit a scheduled money item (an expected incoming / outgoing payment
/// with a due date). Created from inside a project inherits that project's id;
/// the global add sheet exposes the project picker.
struct ScheduledItemEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Project.sortOrder), SortDescriptor(\Project.createdAt, order: .reverse)])
    private var projects: [Project]

    /// `nil` → create; non-nil → edit that item.
    let item: ScheduledItem?
    /// When created inside a project, its id (pre-fills + is offered in the picker).
    let defaultProjectID: UUID?
    /// Called after a successful save/create so the caller can reschedule reminders.
    var onChange: (() -> Void)?

    @State private var direction: ScheduledDirection
    @State private var amountText: String
    @State private var currency: Currency
    @State private var title: String
    @State private var descriptionText: String
    @State private var counterparty: String
    @State private var dueDate: Date
    @State private var selectedProjectID: UUID?

    init(item: ScheduledItem?, defaultProjectID: UUID? = nil, onChange: (() -> Void)? = nil) {
        self.item = item
        self.defaultProjectID = defaultProjectID
        self.onChange = onChange
        _direction = State(initialValue: item?.direction ?? .outgoing)
        _amountText = State(initialValue: item.map { "\($0.amount)" } ?? "")
        _currency = State(initialValue: item?.currency ?? .ron)
        _title = State(initialValue: item?.title ?? "")
        _descriptionText = State(initialValue: item?.descriptionText ?? "")
        _counterparty = State(initialValue: item?.counterparty ?? "")
        _dueDate = State(initialValue: item?.dueDate ?? Date())
        _selectedProjectID = State(initialValue: item?.projectID ?? defaultProjectID)
    }

    private var parsedAmount: Decimal? {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: "."))
    }
    private var canSave: Bool {
        guard let amount = parsedAmount, amount > 0 else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var activeProjects: [ProjectSnapshot] {
        projects.filter { !$0.archived }.map(\.snapshot)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("scheduled.direction", selection: $direction) {
                        ForEach(ScheduledDirection.allCases, id: \.self) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("scheduled.directionPicker")

                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(Typography.amount(.title3, weight: .semibold))
                            .accessibilityIdentifier("scheduled.amountField")
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { c in Text(c.displayCode).tag(c) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("scheduled.currencyToggle")
                    }
                } header: {
                    Text("scheduled.section.money")
                }
                .listRowBackground(Palette.surface)

                Section {
                    TextField("scheduled.title.placeholder", text: $title)
                        .accessibilityIdentifier("scheduled.titleField")
                    TextField("scheduled.counterparty.placeholder", text: $counterparty)
                        .accessibilityIdentifier("scheduled.counterpartyField")
                    TextField("scheduled.notes.placeholder", text: $descriptionText, axis: .vertical)
                    DatePicker("scheduled.dueDate", selection: $dueDate, displayedComponents: .date)
                        .accessibilityIdentifier("scheduled.dueDatePicker")
                    ProjectPickerRow(projects: activeProjects, selectedID: $selectedProjectID)
                } header: {
                    Text("scheduled.section.details")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(item == nil ? "scheduled.create.title" : "scheduled.edit.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("scheduled.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                        .tint(Palette.accent)
                        .accessibilityIdentifier("scheduled.save")
                }
            }
        }
    }

    private func save() {
        guard let amount = parsedAmount, amount > 0 else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanParty = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item {
            item.direction = direction
            item.amount = amount
            item.currency = currency
            item.title = cleanTitle
            item.descriptionText = descriptionText
            item.counterparty = cleanParty.isEmpty ? nil : cleanParty
            item.dueDate = dueDate
            item.projectID = selectedProjectID
        } else {
            let created = ScheduledItem(
                direction: direction, amount: amount, currency: currency,
                title: cleanTitle, descriptionText: descriptionText,
                counterparty: cleanParty.isEmpty ? nil : cleanParty,
                dueDate: dueDate, projectID: selectedProjectID
            )
            modelContext.insert(created)
        }
        try? modelContext.save()
        onChange?()
        dismiss()
    }
}
