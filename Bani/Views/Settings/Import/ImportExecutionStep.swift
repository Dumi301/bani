import SwiftUI

/// Execution screen (C4): a determinate progress bar with a live count and a
/// cancel button. Cancel rolls back this run's rows via the batch id (handled by
/// `ImportRunner`), so an import is never left half-visible.
struct ImportExecutionStep: View {
    @Bindable var model: ImportWizardModel
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.sectionSpacing) {
            Spacer()
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(Palette.accent)
            Text("import.exec.title")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)

            VStack(spacing: metrics.elementSpacing) {
                ProgressView(value: Double(model.progress.processed), total: Double(max(model.progress.total, 1)))
                    .tint(Palette.accent)
                    .accessibilityIdentifier("import.exec.progress")
                Text(verbatim: "\(model.progress.processed) / \(model.progress.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.secondaryInk)
            }
            .padding(.horizontal, metrics.screenPadding)

            Button(role: .destructive) {
                model.cancelImport()
            } label: {
                Text("import.exec.cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color("BaniTagWork"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(MetalPlateButtonStyle())
            .accessibilityIdentifier("import.exec.cancelButton")

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Summary screen (C5): imported N · skipped M (expandable reasons) · context
/// applied, plus an Undo-this-import button that deletes the whole batch.
struct ImportSummaryStep: View {
    @Bindable var model: ImportWizardModel
    var onClose: () -> Void
    @Environment(\.metrics) private var metrics
    @State private var showUndoConfirm = false

    var body: some View {
        Form {
            Section {
                summaryRow("import.summary.imported", value: "\(model.importedCount)", emphasize: true)
                summaryRow("import.summary.skipped", value: "\(model.skippedCount)")
                summaryRow("import.summary.context", value: model.contextChoiceLabel)
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.accent)
                    Text("import.summary.title").foregroundStyle(Palette.secondaryInk)
                }
            }

            if !model.skippedRows.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(model.skippedRows, id: \.sourceRow) { skipped in
                            HStack {
                                Text("import.preview.rowN \(skipped.sourceRow)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Palette.ink)
                                Spacer()
                                Text(skipped.reason.label)
                                    .font(.caption)
                                    .foregroundStyle(Palette.secondaryInk)
                            }
                            .listRowBackground(Palette.surface)
                        }
                    } label: {
                        Text("import.summary.skippedReasons").foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.accent)
                    .listRowBackground(Palette.surface)
                }
            }

            Section {
                Button(role: .destructive) {
                    showUndoConfirm = true
                } label: {
                    Text("import.summary.undo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color("BaniTagWork"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(MetalPlateButtonStyle())
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("import.summary.undoButton")

                Button {
                    onClose()
                } label: {
                    Text("import.summary.done")
                        .font(.headline)
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(MetalPlateButtonStyle(accentWash: true))
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("import.summary.doneButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .confirmationDialog(
            Text("import.summary.undo.confirm \(model.importedCount)"),
            isPresented: $showUndoConfirm,
            titleVisibility: .visible
        ) {
            Button("import.summary.undo", role: .destructive) {
                model.undoCompletedImport()
                onClose()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, value: String, emphasize: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Palette.ink)
            Spacer()
            Text(value)
                .font(emphasize ? .title3.monospacedDigit().weight(.bold) : .body.monospacedDigit())
                .foregroundStyle(emphasize ? Palette.accent : Palette.secondaryInk)
        }
        .listRowBackground(Palette.surface)
    }
}
