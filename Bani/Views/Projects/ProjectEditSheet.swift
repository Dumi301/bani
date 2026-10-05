import SwiftUI
import SwiftData

/// Create a new project (or a unit inside one) or edit an existing one: name,
/// swatch, and — v0.4 — where it sits in the tree, its status, the expected
/// sale and the voice aliases. Never deletes — removal is a card context-menu
/// action (archive, or delete only when the project has no transactions).
struct ProjectEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var projects: [Project]

    /// `nil` → create; non-nil → edit that project.
    let project: Project?

    @State private var name: String
    @State private var colorIndex: Int
    @State private var status: ProjectStatus
    /// v0.4 — the lot this unit belongs to (`nil` = top level).
    @State private var parentID: UUID?
    @State private var expectedSaleText: String
    @State private var hasSaleDate: Bool
    @State private var expectedSaleDate: Date
    @State private var aliasesText: String

    /// - parentID: pre-set parent when creating a unit from a lot's card.
    init(project: Project?, parentID: UUID? = nil) {
        self.project = project
        _name = State(initialValue: project?.name ?? "")
        _colorIndex = State(initialValue: project?.colorIndex ?? 0)
        _status = State(initialValue: project?.status ?? .active)
        _parentID = State(initialValue: project?.parentProjectID ?? parentID)
        _expectedSaleText = State(initialValue: project?.expectedSalePrice.map { "\($0)" } ?? "")
        _hasSaleDate = State(initialValue: project?.expectedSaleDate != nil)
        _expectedSaleDate = State(initialValue: project?.expectedSaleDate ?? Date())
        _aliasesText = State(initialValue: project?.aliasesRaw ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Possible parents: active top-level projects other than this one (the
    /// tree is one level deep — a lot holds units; units hold nothing).
    private var parentOptions: [Project] {
        projects.filter { !$0.archived && $0.parentProjectID == nil && $0.id != project?.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var parsedSalePrice: Decimal? {
        let clean = expectedSaleText.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        guard !clean.isEmpty, let value = Decimal(string: clean), value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("project.name.placeholder", text: $name)
                        .accessibilityIdentifier("project.nameField")
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

                // v0.4 — tree position + status.
                Section {
                    if !parentOptions.isEmpty {
                        Picker("project.parent.label", selection: $parentID) {
                            Text("project.action.noParent").tag(UUID?.none)
                            ForEach(parentOptions, id: \.id) { parent in
                                Text(parent.name).tag(UUID?.some(parent.id))
                            }
                        }
                        .accessibilityIdentifier("project.parentPicker")
                    }
                    Picker("project.status.label", selection: $status) {
                        ForEach([ProjectStatus.active, .prospect, .finished], id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("project.statusPicker")
                } header: {
                    Text("project.structure.label")
                }
                .listRowBackground(Palette.surface)

                // v0.4 — the expected sale feeds the card's expected profit and
                // (v0.6) the balance timeline. Empty = held / rented.
                Section {
                    TextField("project.sale.price.placeholder", text: $expectedSaleText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("project.salePriceField")
                    Toggle("project.sale.date.toggle", isOn: $hasSaleDate)
                    if hasSaleDate {
                        DatePicker("project.sale.date.toggle", selection: $expectedSaleDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                } header: {
                    Text("project.sale.label")
                }
                .listRowBackground(Palette.surface)

                // v0.4 — closed vocabulary for voice ("500 lei lui Ion, casa 3").
                Section {
                    TextField("project.aliases.placeholder", text: $aliasesText)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("project.aliasesField")
                } header: {
                    Text("project.aliases.label")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(project == nil ? "project.create.title" : "project.edit.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("project.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                        .tint(Palette.accent)
                        .accessibilityIdentifier("project.edit.save")
                }
            }
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
                .accessibilityIdentifier("project.swatch.\(index)")
            }
        }
        .padding(.vertical, 6)
    }

    private func save() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let aliases = aliasesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let saleDate: Date? = hasSaleDate ? expectedSaleDate : nil
        if let project {
            project.name = clean
            project.colorIndex = colorIndex
            project.status = status
            project.parentProjectID = parentID
            project.expectedSalePrice = parsedSalePrice
            project.expectedSaleDate = saleDate
            project.aliasesRaw = aliases.isEmpty ? nil : aliases
        } else {
            let nextSort = (projects.map(\.sortOrder).max() ?? -1) + 1
            let created = Project(name: clean, status: status, colorIndex: colorIndex, sortOrder: nextSort,
                                  parentProjectID: parentID, expectedSalePrice: parsedSalePrice,
                                  expectedSaleDate: saleDate, aliasesRaw: aliases.isEmpty ? nil : aliases)
            modelContext.insert(created)
        }
        try? modelContext.save()
        dismiss()
    }
}
