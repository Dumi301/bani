import SwiftUI
import SwiftData

/// The Excel/CSV history-import wizard (C1–C5). A self-contained flow presented
/// from Settings → Import history. Reads the file, guesses the mapping, previews,
/// imports in the background, and offers undo. Cold Metal tokens throughout;
/// localized ro + en; density-aware via `@Environment(\.metrics)`.
struct ImportWizardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.metrics) private var metrics

    @Query(sort: \CustomCategory.createdAt, order: .forward) private var customs: [CustomCategory]
    @Query private var categoryRules: [CategoryRule]

    @State private var model = ImportWizardModel()
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .intro:           introStep
                case .pickSheet:       sheetPickStep
                case .mapping:         ImportMappingStep(model: model)
                case .matchCategories: ImportCategoryMatchStep(model: model)
                case .preview:         ImportPreviewStep(model: model)
                case .executing:       ImportExecutionStep(model: model)
                case .summary:         ImportSummaryStep(model: model, onClose: { dismiss() })
                }
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("import.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.step != .executing {
                        Button("Cancel") { dismiss() }
                            .tint(Palette.accent)
                            .accessibilityIdentifier("import.cancelButton")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: DocumentReader.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.loadDocument(from: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .task {
            model.container = modelContext.container
            model.modelContext = modelContext
            syncSnapshots()
            if ProcessInfo.processInfo.arguments.contains("-importUITest") {
                model.loadUITestFixture()
            }
        }
        .onChange(of: customs.count) { _, _ in syncSnapshots() }
        .onChange(of: categoryRules.count) { _, _ in syncSnapshots() }
    }

    private func syncSnapshots() {
        model.customCategories = customs.map(\.snapshot)
        model.ruleSnapshots = categoryRules.map {
            CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, customCategoryID: $0.customCategoryID, origin: $0.origin, hitCount: $0.hitCount)
        }
    }

    // MARK: - Intro (file pick, C1)

    private var introStep: some View {
        VStack(spacing: metrics.sectionSpacing) {
            Spacer()
            Image(systemName: "tablecells")
                .font(.system(size: 52))
                .foregroundStyle(Palette.accent)
            VStack(spacing: metrics.elementSpacing) {
                Text("import.intro.title")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text("import.intro.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, metrics.screenPadding)

            if model.isReading {
                ProgressView().tint(Palette.accent)
            } else {
                Button {
                    model.errorMessage = nil
                    showFileImporter = true
                } label: {
                    Text("import.intro.choose")
                        .font(.headline)
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(MetalPlateButtonStyle(accentWash: true))
                .padding(.horizontal, metrics.screenPadding)
                .accessibilityIdentifier("import.chooseFileButton")
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color("BaniTagWork"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, metrics.screenPadding)
                    .accessibilityIdentifier("import.errorMessage")
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sheet picker (multi-sheet xlsx, C1)

    private var sheetPickStep: some View {
        Form {
            Section {
                ForEach(model.document?.sheets ?? []) { sheet in
                    Button {
                        model.selectSheet(sheet)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sheet.name ?? String(localized: "import.sheet.unnamed"))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Palette.ink)
                                Text(CountLabels.results(sheet.rowCount))
                                    .font(.caption)
                                    .foregroundStyle(Palette.secondaryInk)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.secondaryInk)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            } header: {
                Text("import.sheet.pick")
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
    }
}
