import SwiftUI
import SwiftData

/// Create a new project or rename / recolor an existing one. Name + one of the
/// fixed 8 swatches. Never deletes — removal is a card context-menu action
/// (archive, or delete only when the project has no transactions).
struct ProjectEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var projects: [Project]

    /// `nil` → create; non-nil → edit that project.
    let project: Project?

    @State private var name: String
    @State private var colorIndex: Int

    init(project: Project?) {
        self.project = project
        _name = State(initialValue: project?.name ?? "")
        _colorIndex = State(initialValue: project?.colorIndex ?? 0)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if let project {
            project.name = clean
            project.colorIndex = colorIndex
        } else {
            let nextSort = (projects.map(\.sortOrder).max() ?? -1) + 1
            let created = Project(name: clean, colorIndex: colorIndex, sortOrder: nextSort)
            modelContext.insert(created)
        }
        try? modelContext.save()
        dismiss()
    }
}
