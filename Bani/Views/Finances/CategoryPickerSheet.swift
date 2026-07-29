import SwiftUI
import SwiftData

/// Reusable horizontal category chip picker (C2): preset chips + custom-category
/// chips + a trailing "+ New category" chip that opens the creation sheet. Used
/// by the confirmation card and the edit sheet so both select/learn through the
/// same seam and both surface custom categories.
struct CategoryChipPicker: View {
    @Binding var selection: CategoryRef?
    let customCategories: [CustomCategory]
    var includeNone: Bool = false
    var onCreateNew: () -> Void

    private var lookup: CustomCategoryLookup { customCategories.lookup }
    private var refs: [CategoryRef] {
        TransactionCategory.allCases.map { CategoryRef.preset($0) }
            + customCategories.map { CategoryRef.custom($0.id) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if includeNone {
                    chip(ref: nil, style: CategoryStyle(
                        label: String(localized: "category.none"),
                        systemImage: "circle.dashed",
                        color: Color("BaniSecondaryInk")
                    ))
                }
                ForEach(refs, id: \.id) { ref in
                    chip(ref: ref, style: categoryStyle(ref, customs: lookup))
                }
                newChip
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("category.chipPicker")
    }

    private func chip(ref: CategoryRef?, style: CategoryStyle) -> some View {
        let isSelected = selection == ref
        return Button {
            selection = ref
        } label: {
            HStack(spacing: 4) {
                Image(systemName: style.systemImage)
                Text(style.label)
            }
            .font(.system(.caption, design: .rounded).weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? style.color.opacity(0.22) : Color("BaniCanvas"), in: Capsule())
            .foregroundStyle(isSelected ? style.color : Color("BaniInk"))
        }
        .buttonStyle(.plain)
    }

    private var newChip: some View {
        Button(action: onCreateNew) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("category.new")
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color("BaniAccent").opacity(0.12), in: Capsule())
            .foregroundStyle(Color("BaniAccent"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category.newButton")
    }
}

/// Compact inline sheet to create OR edit a custom category (C2/C4): name field,
/// curated symbol grid, the 8-swatch palette, a live preview chip, and inline
/// duplicate rejection (normalized-insensitive).
struct NewCategorySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// `nil` = create a new category; non-nil = edit that one (C4).
    let editing: CustomCategory?
    /// Called with the created/updated category so the caller can select it.
    var onSaved: (CustomCategory) -> Void

    @State private var name: String
    @State private var symbol: String
    @State private var colorIndex: Int
    @State private var showDuplicate = false

    init(editing: CustomCategory? = nil, onSaved: @escaping (CustomCategory) -> Void) {
        self.editing = editing
        self.onSaved = onSaved
        _name = State(initialValue: editing?.name ?? "")
        _symbol = State(initialValue: editing?.symbolName ?? CustomCategoryPalette.defaultSymbol)
        _colorIndex = State(initialValue: editing?.colorIndex ?? CustomCategoryPalette.defaultColorIndex)
    }

    private let symbolColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty }
    private var accent: Color { CustomCategoryPalette.color(colorIndex) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("category.name.placeholder", text: $name)
                        .accessibilityIdentifier("newCategory.nameField")
                        .onChange(of: name) { _, _ in showDuplicate = false }
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                        Text(trimmed.isEmpty ? String(localized: "category.name.placeholder") : trimmed)
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(accent)
                    if showDuplicate {
                        Text("category.duplicate")
                            .font(.caption)
                            .foregroundStyle(Color("BaniTagWork"))
                            .accessibilityIdentifier("newCategory.duplicateError")
                    }
                } header: {
                    Text("category.name")
                }

                Section {
                    LazyVGrid(columns: symbolColumns, spacing: 10) {
                        ForEach(CustomCategoryPalette.symbols, id: \.self) { option in
                            Button { symbol = option } label: {
                                Image(systemName: option)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .background(
                                        symbol == option ? accent.opacity(0.22) : Color("BaniCanvas"),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .foregroundStyle(symbol == option ? accent : Color("BaniInk"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("category.symbol")
                }

                Section {
                    LazyVGrid(columns: swatchColumns, spacing: 10) {
                        ForEach(0..<CustomCategoryPalette.count, id: \.self) { index in
                            Button { colorIndex = index } label: {
                                Circle()
                                    .fill(CustomCategoryPalette.color(index))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle().strokeBorder(Color("BaniInk"), lineWidth: colorIndex == index ? 2.5 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("category.color")
                }
            }
            .navigationTitle(editing == nil ? Text("category.new.title") : Text("category.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("newCategory.saveButton")
                }
            }
        }
    }

    private func save() {
        if let editing {
            if CustomCategoryStore.update(editing, name: trimmed, symbolName: symbol, colorIndex: colorIndex, in: modelContext) {
                onSaved(editing)
                dismiss()
            } else {
                showDuplicate = true
            }
        } else if let created = CustomCategoryStore.create(name: trimmed, symbolName: symbol, colorIndex: colorIndex, in: modelContext) {
            onSaved(created)
            dismiss()
        } else {
            showDuplicate = true
        }
    }
}
