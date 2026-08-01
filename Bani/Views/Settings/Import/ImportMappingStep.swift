import SwiftUI

/// Column-mapping screen (C2): auto-guessed field → column pickers the user can
/// override, date-format choice (with an ambiguity prompt), fixed-vs-column
/// currency/context, and the negatives policy (shown only when negatives exist).
struct ImportMappingStep: View {
    @Bindable var model: ImportWizardModel
    @Environment(\.metrics) private var metrics

    var body: some View {
        Form {
            requiredSection
            optionalSection
            if model.parseResult?.negativesFound == true { negativesSection }
            continueSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .onChange(of: model.mapping.dateColumn) { _, _ in model.detectDateFormat() }
        .onChange(of: model.mapping) { _, _ in model.refreshParse() }
    }

    // MARK: - Required

    private var requiredSection: some View {
        Section {
            columnPicker("import.field.date", selection: $model.mapping.dateColumn, includeNone: false)
                .accessibilityIdentifier("import.map.date")
            Picker("import.field.dateFormat", selection: $model.mapping.dateFormat) {
                ForEach(ImportDateFormat.allCases) { format in
                    Text(verbatim: "\(format.label) · \(format.sample)").tag(format)
                }
            }
            .listRowBackground(Palette.surface)
            .accessibilityIdentifier("import.map.dateFormat")
            if model.dateAmbiguous {
                Text("import.map.dateAmbiguous")
                    .font(.caption)
                    .foregroundStyle(Color("BaniTagWork"))
                    .listRowBackground(Palette.surface)
            }
            columnPicker("import.field.amount", selection: $model.mapping.amountColumn, includeNone: false)
                .accessibilityIdentifier("import.map.amount")
            columnPicker("import.field.description", selection: $model.mapping.descriptionColumn, includeNone: false)
                .accessibilityIdentifier("import.map.description")
        } header: {
            Text("import.map.required").foregroundStyle(Palette.secondaryInk)
        } footer: {
            Text("import.map.required.footer").foregroundStyle(Palette.secondaryInk)
        }
    }

    // MARK: - Optional

    private var optionalSection: some View {
        Section {
            // Currency: a column, or a fixed RON/EUR choice.
            columnPicker("import.field.currency", selection: $model.mapping.currencyColumn, includeNone: true)
                .accessibilityIdentifier("import.map.currency")
            if !model.mapping.usesCurrencyColumn {
                Picker("import.field.currency.fixed", selection: $model.mapping.fixedCurrency) {
                    ForEach(Currency.allCases, id: \.self) { c in Text(c.displayCode).tag(c) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Palette.surface)
            }

            // Category: an optional column.
            columnPicker("import.field.category", selection: $model.mapping.categoryColumn, includeNone: true)
                .accessibilityIdentifier("import.map.category")

            // Context: a column, or a fixed Personal/Work choice (the default path).
            columnPicker("import.field.context", selection: $model.mapping.contextColumn, includeNone: true)
                .accessibilityIdentifier("import.map.context")
            if !model.mapping.usesContextColumn {
                Picker("import.field.context.fixed", selection: $model.mapping.fixedContext) {
                    ForEach(TransactionContext.allCases, id: \.self) { ctx in Text(ctx.label).tag(ctx) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Palette.surface)
            }
        } header: {
            Text("import.map.optional").foregroundStyle(Palette.secondaryInk)
        } footer: {
            Text("import.map.optional.footer").foregroundStyle(Palette.secondaryInk)
        }
    }

    // MARK: - Negatives

    private var negativesSection: some View {
        Section {
            Picker("import.field.negatives", selection: $model.mapping.negativesPolicy) {
                ForEach(NegativesPolicy.allCases) { policy in Text(policy.label).tag(policy) }
            }
            .listRowBackground(Palette.surface)
            .accessibilityIdentifier("import.map.negatives")
        } header: {
            Text("import.map.negatives").foregroundStyle(Palette.secondaryInk)
        }
    }

    // MARK: - Continue

    private var continueSection: some View {
        Section {
            VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                HStack {
                    Text("import.map.ready").font(.subheadline).foregroundStyle(Palette.secondaryInk)
                    Spacer()
                    Text(CountLabels.results(model.totalRowCount))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
                if model.skippedCount > 0 {
                    HStack {
                        Text("import.map.willSkip").font(.caption).foregroundStyle(Palette.secondaryInk)
                        Spacer()
                        Text("\(model.skippedCount)").font(.caption.monospacedDigit()).foregroundStyle(Palette.secondaryInk)
                    }
                }
                Button {
                    model.continueFromMapping()
                } label: {
                    Text("import.map.continue")
                        .font(.headline)
                        .foregroundStyle(model.mapping.isComplete ? Palette.accent : Palette.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(MetalPlateButtonStyle(accentWash: model.mapping.isComplete))
                .disabled(!model.mapping.isComplete)
                .accessibilityIdentifier("import.map.continueButton")
            }
            .padding(.vertical, metrics.rowVInset)
            .listRowBackground(Palette.surface)
        }
    }

    // MARK: - Column picker

    private func columnPicker(_ title: LocalizedStringKey, selection: Binding<Int?>, includeNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if includeNone {
                Text("import.map.none").tag(Optional<Int>.none)
            }
            ForEach(Array(model.columnTitles.enumerated()), id: \.offset) { pair in
                Text(columnLabel(index: pair.offset, title: pair.element)).tag(Optional(pair.offset))
            }
        }
        .listRowBackground(Palette.surface)
    }

    private func columnLabel(index: Int, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "import.map.columnN \(index + 1)") }
        return trimmed
    }
}
