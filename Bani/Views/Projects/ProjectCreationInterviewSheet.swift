import SwiftUI
import SwiftData

/// v1.3 "People registry" run — Board 2's guided "New project" interview,
/// replacing the bare `ProjectEditSheet(project: nil)` at the ProjectsView "+"
/// entry point. Three steps, atomic create on the last one:
///   1. Identity — name + one of the fixed 8 swatches (`ProjectEditSheet`'s
///      color picker; the model has no separate symbol field, so "color" IS
///      the visual identity here).
///   2. Expected money — OPTIONAL, skippable: collect zero or more
///      `ScheduledItem` drafts (in/out, amount, due date, P2 recurrence)
///      in-memory before anything is persisted.
///   3. Summary — review, then insert the `Project` + every drafted item and
///      save ONCE: a Cancel at any step leaves nothing behind, and a
///      successful Create either persists everything or (on a SwiftData save
///      failure) nothing new is left half-written across two separate saves.
///
/// `ProjectEditSheet` is UNCHANGED and remains the rename/recolor path
/// (`ProjectsView`'s `renamingProject` sheet) — this sheet only replaces bare
/// creation.
struct ProjectCreationInterviewSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var projects: [Project]

    @State private var step: Step = .identity

    // Step 1 — identity
    @State private var name = ""
    @State private var colorIndex = 0

    // Step 2 — expected money drafts (not yet persisted)
    @State private var drafts: [DraftScheduledItem] = []
    @State private var draftDirection: ScheduledDirection = .incoming
    @State private var draftAmountText = ""
    @State private var draftCurrency: Currency = .ron
    @State private var draftTitle = ""
    @State private var draftDueDate = Date()
    @State private var draftRecurrence: RecurrenceRule = .none

    private enum Step { case identity, money, summary }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .identity: identityStep
                case .money: moneyStep
                case .summary: summaryStep
                }
            }
            .navigationTitle("project.create.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("project.interview.cancel")
                }
            }
        }
    }

    // MARK: - Step 1: identity

    private var canProceedFromIdentity: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var identityStep: some View {
        Form {
            Section {
                TextField("project.name.placeholder", text: $name)
                    .accessibilityIdentifier("project.interview.nameField")
            } header: {
                Text("project.name.label")
            }
            .listRowBackground(Palette.surface)

            Section {
                swatchGrid
            } header: {
                Text("project.color.label")
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            nextButton(disabled: !canProceedFromIdentity) { step = .money }
        }
    }

    private var swatchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
            ForEach(0..<CustomCategoryPalette.count, id: \.self) { index in
                Button {
                    colorIndex = index
                } label: {
                    Circle()
                        .fill(CustomCategoryPalette.color(index))
                        .frame(width: 34, height: 34)
                        .overlay {
                            Circle().strokeBorder(Palette.ink, lineWidth: colorIndex == index ? 3 : 0)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project.interview.swatch.\(index)")
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Step 2: expected money (optional, skippable)

    private var draftParsedAmount: Decimal? {
        Decimal(string: draftAmountText.replacingOccurrences(of: ",", with: "."))
    }
    private var canAddDraft: Bool {
        guard let amount = draftParsedAmount else { return false }
        return amount > 0
    }

    private var moneyStep: some View {
        Form {
            Section {
                Picker("scheduled.direction", selection: $draftDirection) {
                    ForEach(ScheduledDirection.allCases, id: \.self) { d in Text(d.label).tag(d) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("project.interview.directionPicker")

                HStack {
                    TextField("0", text: $draftAmountText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("project.interview.amountField")
                    Picker("Currency", selection: $draftCurrency) {
                        ForEach(Currency.allCases, id: \.self) { c in Text(c.displayCode).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                TextField("scheduled.title.placeholder", text: $draftTitle)
                    .accessibilityIdentifier("project.interview.titleField")
                DatePicker("scheduled.dueDate", selection: $draftDueDate, displayedComponents: .date)
                    .accessibilityIdentifier("project.interview.dueDatePicker")
                Picker("scheduled.recurrence", selection: $draftRecurrence) {
                    ForEach(RecurrenceRule.allCases, id: \.self) { r in Text(r.label).tag(r) }
                }
                .accessibilityIdentifier("project.interview.recurrencePicker")

                Button {
                    addDraft()
                } label: {
                    Label("project.interview.addItem", systemImage: "plus.circle.fill")
                }
                .disabled(!canAddDraft)
                .accessibilityIdentifier("project.interview.addItemButton")
            } header: {
                Text("project.interview.money.header")
            } footer: {
                Text("project.interview.money.footer")
            }
            .listRowBackground(Palette.surface)

            if !drafts.isEmpty {
                Section {
                    ForEach(drafts) { draft in
                        draftRow(draft)
                    }
                    .onDelete { indexSet in drafts.remove(atOffsets: indexSet) }
                } header: {
                    Text("project.interview.money.added \(drafts.count)")
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button("project.interview.skip") { step = .summary }
                    .accessibilityIdentifier("project.interview.skipButton")
                Spacer()
                Button("project.interview.next") { step = .summary }
                    .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
                    .accessibilityIdentifier("project.interview.nextButton")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func addDraft() {
        guard let amount = draftParsedAmount, amount > 0 else { return }
        let cleanTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts.append(DraftScheduledItem(
            direction: draftDirection,
            amount: amount,
            currency: draftCurrency,
            title: cleanTitle.isEmpty ? draftDirection.label : cleanTitle,
            dueDate: draftDueDate,
            recurrence: draftRecurrence
        ))
        draftAmountText = ""
        draftTitle = ""
        draftRecurrence = .none
    }

    private func draftRow(_ draft: DraftScheduledItem) -> some View {
        HStack {
            Image(systemName: draft.direction.systemImage)
                .foregroundStyle(draft.direction == .incoming ? Palette.accent : Palette.secondaryInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title).font(.subheadline)
                Text(draft.dueDate.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer(minLength: 6)
            Text("\(draft.amount.formatted(.number.precision(.fractionLength(0...2)))) \(draft.currency.displayCode)")
                .font(Typography.mono(.caption))
        }
        .accessibilityIdentifier("project.interview.draftRow")
    }

    // MARK: - Step 3: summary

    private var summaryStep: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle().fill(CustomCategoryPalette.color(colorIndex)).frame(width: 14, height: 14)
                    Text(name).font(.headline)
                }
            } header: {
                Text("project.interview.summary.identity")
            }
            .listRowBackground(Palette.surface)

            if drafts.isEmpty {
                Section {
                    Text("project.interview.summary.noMoney")
                        .foregroundStyle(Palette.secondaryInk)
                }
                .listRowBackground(Palette.surface)
            } else {
                Section {
                    ForEach(drafts) { draftRow($0) }
                } header: {
                    Text("project.interview.money.added \(drafts.count)")
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button("project.interview.back") { step = .money }
                    .accessibilityIdentifier("project.interview.backButton")
                Spacer()
                Button("project.interview.create") { create() }
                    .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
                    .accessibilityIdentifier("project.interview.createButton")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func nextButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button("project.interview.next", action: action)
            .disabled(disabled)
            .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("project.interview.nextButton")
    }

    // MARK: - Create (atomic)

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let nextSort = (projects.map(\.sortOrder).max() ?? -1) + 1
        let project = Project(name: clean, colorIndex: colorIndex, sortOrder: nextSort)
        modelContext.insert(project)
        for draft in drafts {
            let item = ScheduledItem(
                direction: draft.direction,
                amount: draft.amount,
                currency: draft.currency,
                title: draft.title,
                dueDate: draft.dueDate,
                projectID: project.id,
                recurrence: draft.recurrence
            )
            modelContext.insert(item)
        }
        try? modelContext.save()
        dismiss()
    }
}

/// A not-yet-persisted scheduled-money line collected during step 2, before
/// the atomic create in step 3.
private struct DraftScheduledItem: Identifiable {
    let id = UUID()
    var direction: ScheduledDirection
    var amount: Decimal
    var currency: Currency
    var title: String
    var dueDate: Date
    var recurrence: RecurrenceRule
}
