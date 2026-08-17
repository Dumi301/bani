import SwiftUI
import SwiftData

/// A project's Money-schedule pane: pending items sorted by due date, overdue on
/// top in the semantic warning color, done section collapsed. Add / edit via a
/// sheet; "Mark done" opens a pre-filled confirmation card that creates a real,
/// linked transaction and flips the item to done.
struct ProjectScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale

    let projectID: UUID

    @Query private var allItems: [ScheduledItem]

    @State private var creating = false
    @State private var editingItem: ScheduledItem?
    @State private var markingDone: ScheduledItem?

    private var warningColor: Color { Color("BaniTagWork") }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: metrics.rowSpacing) {
                addButton

                if pendingItems.isEmpty && doneItems.isEmpty {
                    emptyState
                } else {
                    if !overdue.isEmpty {
                        section(title: String(localized: "scheduled.section.overdue"), tint: warningColor) {
                            ForEach(overdue, id: \.id) { row($0, overdue: true) }
                        }
                    }
                    if !upcoming.isEmpty {
                        section(title: String(localized: "scheduled.section.upcoming"), tint: Palette.secondaryInk) {
                            ForEach(upcoming, id: \.id) { row($0, overdue: false) }
                        }
                    }
                    if !doneItems.isEmpty {
                        DisclosureGroup {
                            ForEach(doneItems, id: \.id) { row($0, overdue: false) }
                        } label: {
                            Text("scheduled.section.done \(doneItems.count)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.secondaryInk)
                        }
                        .accentColor(Palette.secondaryInk)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.elementSpacing)
        }
        .sheet(isPresented: $creating) {
            ScheduledItemEditSheet(item: nil, defaultProjectID: projectID, onChange: rescheduleReminders)
        }
        .sheet(item: $editingItem) { item in
            ScheduledItemEditSheet(item: item, defaultProjectID: projectID, onChange: rescheduleReminders)
        }
        .sheet(item: $markingDone) { item in
            ScheduledItemMarkDoneSheet(item: item, onDone: rescheduleReminders)
        }
    }

    // MARK: - Rows

    private var addButton: some View {
        Button {
            creating = true
        } label: {
            Label("scheduled.add", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(metrics.cardPadding)
                .metalSurface(cornerRadius: Radius.card)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scheduled.addButton")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding(.top, 4)
    }

    private func row(_ item: ScheduledItem, overdue: Bool) -> some View {
        let tint = overdue ? warningColor : (item.direction == .incoming ? Palette.accent : Palette.ink)
        return HStack(spacing: metrics.elementSpacing) {
            Image(systemName: item.direction.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.direction == .incoming ? Palette.accent : Palette.secondaryInk)
                .frame(width: 30, height: 30)
                .background(Palette.canvas, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(item.status == .done ? Palette.secondaryInk : Palette.ink)
                    .strikethrough(item.status == .done)
                Text(dueText(item, overdue: overdue))
                    .font(.caption2)
                    .foregroundStyle(overdue ? warningColor : Palette.secondaryInk)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.direction == .incoming ? "+" : "−")\(item.amount.formatted(.number.precision(.fractionLength(0...2)))) \(item.currency.displayCode)")
                    .font(Typography.amount(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
                if item.status == .pending {
                    Button {
                        markingDone = item
                    } label: {
                        Text("scheduled.markDone")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scheduled.markDoneButton")
                }
            }
        }
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .contentShape(Rectangle())
        .onTapGesture { if item.status == .pending { editingItem = item } }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                ScheduledItemStore.delete(item, in: modelContext)
                rescheduleReminders()
            } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityIdentifier("scheduled.row")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32))
                .foregroundStyle(Palette.secondaryInk)
            Text("scheduled.empty")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityIdentifier("scheduled.emptyState")
    }

    // MARK: - Derived

    private var projectItems: [ScheduledItem] {
        allItems.filter { $0.projectID == projectID }
    }
    private var pendingItems: [ScheduledItem] {
        projectItems.filter { $0.status == .pending }.sorted { $0.dueDate < $1.dueDate }
    }
    private var overdue: [ScheduledItem] { pendingItems.filter { $0.isOverdue() } }
    private var upcoming: [ScheduledItem] { pendingItems.filter { !$0.isOverdue() } }
    private var doneItems: [ScheduledItem] {
        projectItems.filter { $0.status == .done }.sorted { $0.dueDate > $1.dueDate }
    }

    private func dueText(_ item: ScheduledItem, overdue: Bool) -> String {
        let day = item.dueDate.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        if overdue { return String(localized: "scheduled.overdue \(day)") }
        return String(localized: "scheduled.due \(day)")
    }

    /// Reschedule local notifications after any change (respects the toggle).
    private func rescheduleReminders() {
        ReminderService.refreshFromStore(modelContext)
    }
}

// MARK: - Mark-done confirmation card

/// The pre-filled confirmation card for "Mark done" (the card contract's terminal
/// state): amount / description / direction / project come from the item; saving
/// creates a real linked `Transaction` and flips the item to done. Cancel leaves
/// the item pending; edits are applied before saving.
struct ScheduledItemMarkDoneSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.metrics) private var metrics

    let item: ScheduledItem
    var onDone: (() -> Void)?

    @State private var amountText: String
    @State private var descriptionText: String
    @State private var date = Date()

    init(item: ScheduledItem, onDone: (() -> Void)? = nil) {
        self.item = item
        self.onDone = onDone
        _amountText = State(initialValue: "\(item.amount)")
        _descriptionText = State(initialValue: item.title)
    }

    private var parsedAmount: Decimal? {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: "."))
    }
    private var canSave: Bool { (parsedAmount ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: item.direction.systemImage)
                        Text(item.direction.transactionDirection.label)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)

                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(Typography.amount(.title3, weight: .semibold))
                            .accessibilityIdentifier("markDone.amountField")
                        Text(item.currency.displayCode)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    TextField("Description", text: $descriptionText)
                        .accessibilityIdentifier("markDone.descriptionField")
                    DatePicker("scheduled.dueDate", selection: $date, displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("scheduled.markDone.confirm")
                } footer: {
                    Text("scheduled.markDone.footer")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("scheduled.markDone.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("markDone.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("scheduled.markDone.save") {
                        ScheduledItemStore.markDone(
                            item,
                            amount: parsedAmount,
                            descriptionText: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                            date: date,
                            in: modelContext
                        )
                        onDone?()
                        dismiss()
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                    .tint(Palette.accent)
                    .accessibilityIdentifier("markDone.save")
                }
            }
        }
    }
}
