import SwiftUI

/// Preview screen (C3): first 10 parsed rows rendered as they'll be saved (date,
/// amount + currency, description, category chip, context tag), the total row
/// count, and the detected skip candidates with reasons. The Import button states
/// the count and runs the batch-level dedup guard before executing.
struct ImportPreviewStep: View {
    @Bindable var model: ImportWizardModel
    @Environment(\.metrics) private var metrics

    var body: some View {
        Form {
            if model.cancelledNotice {
                Section {
                    Text("import.preview.cancelledNotice")
                        .font(.footnote)
                        .foregroundStyle(Color("BaniTagWork"))
                        .listRowBackground(Palette.surface)
                }
            }

            Section {
                ForEach(model.previewRows, id: \.sourceRow) { row in
                    previewRow(row).listRowBackground(Palette.surface)
                }
            } header: {
                Text("import.preview.title").foregroundStyle(Palette.secondaryInk)
            } footer: {
                Text("import.preview.showing \(model.previewRows.count) \(model.totalRowCount)")
                    .foregroundStyle(Palette.secondaryInk)
            }

            if !model.skippedRows.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(model.skippedRows, id: \.sourceRow) { skipped in
                            skippedRow(skipped)
                        }
                    } label: {
                        HStack {
                            Text("import.preview.skipped").foregroundStyle(Palette.ink)
                            Spacer()
                            Text("\(model.skippedCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Palette.secondaryInk)
                        }
                    }
                    .tint(Palette.accent)
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("import.preview.skippedDisclosure")
                }
            }

            importSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .confirmationDialog(
            "import.dedup.title",
            isPresented: $model.showDedupWarning,
            titleVisibility: .visible
        ) {
            Button("import.dedup.proceed", role: .destructive) { model.runImport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("import.dedup.message")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                model.requestImport()
            } label: {
                Text("import.preview.import \(model.totalRowCount)")
                    .font(.headline)
                    .foregroundStyle(model.totalRowCount > 0 ? Palette.accent : Palette.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(MetalPlateButtonStyle(accentWash: model.totalRowCount > 0))
            .disabled(model.totalRowCount == 0)
            .listRowBackground(Palette.surface)
            .accessibilityIdentifier("import.preview.importButton")
        }
    }

    // MARK: - Row rendering

    private func previewRow(_ row: ParsedImportRow) -> some View {
        let style = model.previewStyle(for: row)
        return VStack(alignment: .leading, spacing: metrics.elementSpacing) {
            HStack {
                Text(row.date, format: .dateTime.day().month().year())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondaryInk)
                Spacer()
                Text(amountText(row))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text(row.descriptionText)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            HStack(spacing: 6) {
                categoryChip(style)
                contextTag(row.context)
            }
        }
        .padding(.vertical, metrics.rowVInset)
    }

    private func amountText(_ row: ParsedImportRow) -> String {
        let amount = row.amount.formatted(.number.precision(.fractionLength(0...2)))
        return "\(amount) \(row.currency.displayCode)"
    }

    private func categoryChip(_ style: CategoryStyle) -> some View {
        HStack(spacing: 4) {
            Image(systemName: style.systemImage)
            Text(style.label)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(style.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(style.color.opacity(0.18)))
    }

    private func contextTag(_ context: TransactionContext) -> some View {
        let color = Color(context.tagColorName)
        return Text(context.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private func skippedRow(_ skipped: SkippedImportRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("import.preview.rowN \(skipped.sourceRow)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(skipped.reason.label)
                    .font(.caption)
                    .foregroundStyle(Color("BaniTagWork"))
            }
            Text(skippedDetail(skipped))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.secondaryInk)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .listRowBackground(Palette.surface)
    }

    private func skippedDetail(_ s: SkippedImportRow) -> String {
        [s.rawDate, s.rawAmount, s.rawDescription]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
