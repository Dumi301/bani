import SwiftUI
import SwiftData

/// Category-matching screen (C2): lists the category-column values that did NOT
/// auto-match an existing category and lets the user, per value, map it to an
/// existing category, create a new custom one (reusing `NewCategorySheet`), or
/// leave it uncategorized. Auto-matched values are already resolved and never
/// shown here.
struct ImportCategoryMatchStep: View {
    @Bindable var model: ImportWizardModel
    @Query(sort: \CustomCategory.createdAt, order: .forward) private var customs: [CustomCategory]
    @Environment(\.metrics) private var metrics

    /// The value whose "+ New category" sheet is open (nil = closed).
    @State private var newCategoryForValue: String?

    var body: some View {
        Form {
            Section {
                Text("import.match.explain")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Palette.surface)
            }
            ForEach(model.unmatchedCategoryValues, id: \.self) { value in
                Section {
                    CategoryChipPicker(
                        selection: binding(for: value),
                        customCategories: customs,
                        includeNone: true,
                        onCreateNew: { newCategoryForValue = value }
                    )
                    .listRowBackground(Palette.surface)
                } header: {
                    Text(value).foregroundStyle(Palette.secondaryInk)
                }
            }
            continueSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .sheet(isPresented: Binding(
            get: { newCategoryForValue != nil },
            set: { if !$0 { newCategoryForValue = nil } }
        )) {
            NewCategorySheet { created in
                if let value = newCategoryForValue {
                    model.setDecision(.existing(.custom(created.id)), for: value)
                }
            }
        }
    }

    private func binding(for value: String) -> Binding<CategoryRef?> {
        Binding(
            get: {
                if case let .existing(ref) = model.decision(for: value) { return ref }
                return nil
            },
            set: { newValue in
                model.setDecision(newValue.map { .existing($0) } ?? .uncategorized, for: value)
            }
        )
    }

    private var continueSection: some View {
        Section {
            Button {
                model.finishCategoryMatching()
            } label: {
                Text("import.match.continue")
                    .font(.headline)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(MetalPlateButtonStyle(accentWash: true))
            .listRowBackground(Palette.surface)
            .accessibilityIdentifier("import.match.continueButton")
        }
    }
}
