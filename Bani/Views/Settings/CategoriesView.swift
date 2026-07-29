import SwiftUI
import SwiftData

/// Settings → Categories (C4): manage custom categories — create, rename /
/// re-symbol / re-color (tap a row), and delete WITH reassignment (swipe), so a
/// deleted category never orphans its transactions or the learned rules that
/// pointed at it.
struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomCategory.createdAt, order: .forward) private var customCategories: [CustomCategory]

    @State private var editing: CustomCategory?
    @State private var deleting: CustomCategory?
    @State private var isCreating = false

    var body: some View {
        List {
            Section {
                if customCategories.isEmpty {
                    Text("categories.empty")
                        .font(.subheadline)
                        .foregroundStyle(Color("BaniSecondaryInk"))
                        .listRowBackground(Color("BaniSurface"))
                } else {
                    ForEach(customCategories, id: \.id) { category in
                        Button { editing = category } label: { row(category) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color("BaniSurface"))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { deleting = category } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            } footer: {
                Text("categories.footer").foregroundStyle(Color("BaniSecondaryInk"))
            }

            Section {
                Button { isCreating = true } label: {
                    Label("category.new", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color("BaniAccent"))
                }
                .listRowBackground(Color("BaniSurface"))
                .accessibilityIdentifier("categories.addButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("BaniCanvas").ignoresSafeArea())
        .navigationTitle("categories.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isCreating) {
            NewCategorySheet { _ in }
        }
        .sheet(isPresented: editingBinding) {
            if let editing {
                NewCategorySheet(editing: editing) { _ in }
            }
        }
        .sheet(isPresented: deletingBinding) {
            if let deleting {
                ReassignSheet(category: deleting)
            }
        }
    }

    private func row(_ category: CustomCategory) -> some View {
        let count = CustomCategoryStore.transactionCount(for: category.id, in: modelContext)
        let color = CustomCategoryPalette.color(category.colorIndex)
        return HStack(spacing: 12) {
            Image(systemName: category.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.16), in: Circle())
            Text(category.name)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(Color("BaniInk"))
            Spacer()
            Text(CountLabels.transactions(count))
                .font(.caption)
                .foregroundStyle(Color("BaniSecondaryInk"))
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .contentShape(Rectangle())
    }

    // Present sheets via isPresented bindings driven by the optional selection —
    // avoids relying on `.sheet(item:)` Identifiable synthesis for @Model types.
    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }
    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

/// The delete-with-reassignment dialog (C4): choose where the N transactions and
/// the learned rules move before the category is removed — never orphaned.
private struct ReassignSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allCustom: [CustomCategory]

    let category: CustomCategory
    @State private var target: CategoryRef = .preset(.other)

    private var count: Int { CustomCategoryStore.transactionCount(for: category.id, in: modelContext) }
    private var lookup: CustomCategoryLookup { allCustom.lookup }
    private var targetRefs: [CategoryRef] {
        TransactionCategory.allCases.map { CategoryRef.preset($0) }
            + allCustom.filter { $0.id != category.id }.map { CategoryRef.custom($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("categories.moveTo", selection: $target) {
                        ForEach(targetRefs, id: \.id) { ref in
                            let style = categoryStyle(ref, customs: lookup)
                            Label(style.label, systemImage: style.systemImage).tag(ref)
                        }
                    }
                    .accessibilityIdentifier("categories.reassignPicker")
                } header: {
                    Text("\(String(localized: "categories.moveTo")) · \(CountLabels.transactions(count))")
                } footer: {
                    Text("categories.delete.footer")
                }
            }
            .navigationTitle("categories.delete.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        CustomCategoryStore.delete(category, reassignTo: target, in: modelContext)
                        dismiss()
                    }
                    .accessibilityIdentifier("categories.confirmDelete")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
