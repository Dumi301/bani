import SwiftUI
import SwiftData

/// The one screen shown after processing (F) — the UX heart of the one-tap import.
/// Per-file ✓/⚠/✗ chips with counts, plain-language reasons, editable document
/// drafts with low-confidence fields flagged, and grouped questions answered once.
/// NOTHING saves before Confirm; Cancel discards everything.
struct UnderstandingReportView: View {
    @Environment(\.metrics) private var metrics
    /// v1.2a — projects for the batch-level project picker.
    @Query private var projects: [Project]
    @Binding var report: UnderstandingReport
    let onConfirm: () -> Void
    let onCancel: () -> Void
    /// Open the demoted wizard's "fix mapping" hatch for a generic file (D5).
    let onFixMapping: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: metrics.sectionSpacing) {
                    summaryHeader
                    ForEach(Array(report.files.enumerated()), id: \.element.id) { index, _ in
                        fileCard(index)
                    }
                    projectSection
                    questionsSection
                }
                .padding(metrics.screenPadding)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Understanding…")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    // MARK: - Header

    private var summaryHeader: some View {
        VStack(spacing: 6) {
            Text("import.report.summary \(report.totalImported) \(report.files.count)")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            if report.totalSkipped > 0 {
                Text("import.report.skipped \(report.totalSkipped)")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .accessibilityIdentifier("import.report.header")
    }

    // MARK: - Batch project (v1.2a)

    private var activeProjects: [ProjectSnapshot] { projects.filter { !$0.archived }.map(\.snapshot) }

    private var projectBinding: Binding<UUID?> {
        Binding(get: { report.decisions.projectID }, set: { report.decisions.projectID = $0 })
    }

    /// One batch-level project picker applied to every committed row on Confirm
    /// (defaulted to last-used for a Work-defaulting batch; per-row overrides are out).
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: metrics.elementSpacing) {
            Text("import.report.project.title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            ProjectPickerRow(projects: activeProjects, selectedID: projectBinding)
                .accessibilityIdentifier("import.report.projectPicker")
            Text("import.report.project.note")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("import.report.projectSection")
    }

    // MARK: - File card

    @ViewBuilder
    private func fileCard(_ i: Int) -> some View {
        let file = report.files[i]
        VStack(alignment: .leading, spacing: metrics.elementSpacing) {
            HStack(spacing: 8) {
                Image(systemName: file.status.symbol)
                    .foregroundStyle(Color(file.status.tagColorName))
                Text(file.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                if file.status != .failed {
                    Text("\(file.importedCount)")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(Palette.accent)
                }
            }

            if !file.sheets.isEmpty {
                ForEach(file.sheets) { sheet in
                    HStack(spacing: 6) {
                        Text(sheet.name).font(.caption.weight(.medium)).foregroundStyle(Palette.secondaryInk).lineLimit(1)
                        Text(LocalizedStringKey(sheet.roleLabelKey)).font(.caption2).foregroundStyle(Palette.secondaryInk)
                        Spacer()
                        if sheet.importedCount > 0 {
                            Text("import.report.rows \(sheet.importedCount)").font(.caption2).foregroundStyle(Palette.accent)
                        }
                    }
                }
            }

            ForEach(file.noteKeys, id: \.self) { key in
                Label(LocalizedStringKey(key), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }

            if file.isDocument, file.status != .failed, !file.drafts.isEmpty {
                documentEditor(i)
            }

            if file.canFixMapping {
                Button { onFixMapping(i) } label: {
                    Label("import.report.fixMapping", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("import.report.fixMapping")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("import.report.fileCard")
    }

    // MARK: - Document draft editor (E)

    @ViewBuilder
    private func documentEditor(_ i: Int) -> some View {
        let extraction = report.files[i].extraction
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                TextField("0", value: draftAmount(i), format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .font(Typography.amount(.title3, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("import.report.docAmount")
                if lowConfidence(extraction?.amountConfidence) { flag }
                Picker("", selection: draftCurrency(i)) {
                    ForEach(Currency.allCases, id: \.self) { Text($0.displayCode).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
            }
            HStack {
                DatePicker("", selection: draftDate(i), displayedComponents: .date).labelsHidden()
                if report.files[i].drafts.first?.dateWasFallback == true { flag }
                Spacer()
            }
            CounterpartyField(text: draftCounterparty(i), suggestions: [])
            DirectionPicker(selection: draftDirection(i))
            if let summary = report.files[i].drafts.first?.docSummary, !summary.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(Palette.secondaryInk)
            }
        }
    }

    private var flag: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color("BaniTagWork"))
            .accessibilityIdentifier("import.report.lowConfidenceFlag")
    }

    private func lowConfidence(_ value: Double?) -> Bool { (value ?? 1) < 0.6 }

    // MARK: - Questions (F, D4)

    @ViewBuilder
    private var questionsSection: some View {
        let contextFiles = report.files.indices.filter { report.files[$0].needsContextChoice && report.files[$0].status != .failed }
        if !contextFiles.isEmpty || report.duplicateCount > 0 || report.negativesFound {
            VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                Text("import.report.questions")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)

                ForEach(contextFiles, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("import.report.contextFor \(report.files[i].fileName)")
                            .font(.caption).foregroundStyle(Palette.secondaryInk)
                        Picker("", selection: appliedContext(i)) {
                            ForEach(TransactionContext.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("import.report.contextQuestion")
                    }
                }

                if report.duplicateCount > 0 {
                    Toggle(isOn: $report.decisions.skipDuplicates) {
                        Text("import.report.dedup \(report.duplicateCount)")
                            .font(.subheadline)
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("import.report.dedupToggle")
                }

                if report.negativesFound {
                    Picker("import.report.negatives", selection: $report.decisions.negativesPolicy) {
                        ForEach(NegativesPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("import.report.negatives")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.cardPadding)
            .metalSurface(cornerRadius: Radius.card)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) { onCancel() } label: {
                Text("Cancel").font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
            }
            .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button))
            .accessibilityIdentifier("import.report.cancel")

            Button { onConfirm() } label: {
                Text("import.report.confirm \(committableCount)")
                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
            .disabled(committableCount == 0)
            .accessibilityIdentifier("import.report.confirm")
        }
        .padding(.horizontal, metrics.screenPadding)
        .padding(.vertical, metrics.elementSpacing)
        .background(.ultraThinMaterial)
    }

    private var committableCount: Int { report.committableDrafts.count }

    // MARK: - Draft field bindings

    private func appliedContext(_ i: Int) -> Binding<TransactionContext> {
        Binding(get: { report.files[i].appliedContext }, set: { report.files[i].appliedContext = $0 })
    }
    private func draftAmount(_ i: Int) -> Binding<Decimal> {
        Binding(get: { report.files[i].drafts.first?.amount ?? 0 }, set: { if !report.files[i].drafts.isEmpty { report.files[i].drafts[0].amount = $0 } })
    }
    private func draftCurrency(_ i: Int) -> Binding<Currency> {
        Binding(get: { report.files[i].drafts.first?.currency ?? .ron }, set: { if !report.files[i].drafts.isEmpty { report.files[i].drafts[0].currency = $0 } })
    }
    private func draftDate(_ i: Int) -> Binding<Date> {
        Binding(get: { report.files[i].drafts.first?.date ?? Date() }, set: { if !report.files[i].drafts.isEmpty { report.files[i].drafts[0].date = $0; report.files[i].drafts[0].dateWasFallback = false } })
    }
    private func draftCounterparty(_ i: Int) -> Binding<String> {
        Binding(
            get: { report.files[i].drafts.first?.counterparty ?? "" },
            set: { if !report.files[i].drafts.isEmpty { report.files[i].drafts[0].counterparty = $0.isEmpty ? nil : $0 } }
        )
    }
    private func draftDirection(_ i: Int) -> Binding<TransactionDirection> {
        Binding(get: { report.files[i].drafts.first?.direction ?? .expense }, set: { if !report.files[i].drafts.isEmpty { report.files[i].drafts[0].direction = $0 } })
    }
}
