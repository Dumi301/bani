import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Drives the one-tap, all-formats import (D + F): pick files → process down the
/// reading ladder → the understanding report → commit as one batch. Replaces the
/// wizard as the default path; the wizard survives only as the report's fix-mapping
/// hatch (D5).
@MainActor
@Observable
final class ImportFlowModel {
    enum Phase: Equatable { case processing, report, executing, done }

    var phase: Phase = .processing
    var report: UnderstandingReport?
    var progress = ImportProgress(processed: 0, total: 0)
    var importedCount = 0

    var container: ModelContainer?
    var context: ModelContext?

    func start(urls: [URL]) {
        let inputs = urls.compactMap { url -> ImportInput? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImportInput(data: data, fileName: url.lastPathComponent)
        }
        start(inputs: inputs)
    }

    func start(inputs: [ImportInput]) {
        guard let context, !inputs.isEmpty else { return }
        phase = .processing
        let existing = ImportBatchStore.existingImportFingerprints(in: context)
        let importDate = Date()
        Task { [weak self] in
            let extractor = FoundationModelsExtractor()
            let built = await ImportPipeline.buildReport(inputs: inputs, existingFingerprints: existing, importDate: importDate, extractor: extractor)
            await MainActor.run {
                self?.report = built
                self?.phase = .report
            }
        }
    }

    func confirm() {
        guard let container, let report else { return }
        let committable = report.committableDrafts
        let items = committable.map { CommitItem(draft: $0.draft, context: $0.context, attachment: $0.attachment) }
        guard !items.isEmpty else { importedCount = 0; phase = .done; return }

        let names = report.files.map(\.fileName)
        let fileName = names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
        let contexts = Set(items.map(\.context))
        let contextChoice = contexts.count == 1 ? (contexts.first?.rawValue ?? "personal") : "mixed"
        let notes = "files=\(names.count) · imported=\(items.count) · skipped=\(report.totalSkipped)"
        let skipped = report.totalSkipped

        phase = .executing
        progress = ImportProgress(processed: 0, total: items.count)
        let handler: @Sendable (ImportProgress) async -> Void = { [weak self] p in await MainActor.run { self?.progress = p } }
        Task { [weak self] in
            let runner = ImportCommitRunner(modelContainer: container)
            let outcome = await runner.commit(items: items, fileName: fileName, contextChoice: contextChoice, notes: notes, skippedCount: skipped, onProgress: handler)
            await MainActor.run {
                if case let .completed(_, imported) = outcome { self?.importedCount = imported }
                self?.phase = .done
            }
        }
    }
}

/// The full-screen import flow. Launched from Settings → Import (replaces the
/// wizard as the entry). Presents the file picker, processing, the report, then
/// the summary.
struct ImportFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.metrics) private var metrics

    @State private var model = ImportFlowModel()
    @State private var isPickerPresented = false
    @State private var didAutoPresent = false
    @State private var showWizard = false

    var body: some View {
        NavigationStack {
            content
                .background(Palette.canvas.ignoresSafeArea())
        }
        .onAppear {
            model.container = modelContext.container
            model.context = modelContext
            // UI-test seam: bypass the system picker with in-code synthetic files
            // so the report is reachable without the document picker.
            if ProcessInfo.processInfo.arguments.contains("-importReportUITest") {
                if model.report == nil, model.phase != .report {
                    model.start(inputs: ImportUITestFixtures.inputs)
                }
            } else if !didAutoPresent {
                didAutoPresent = true
                isPickerPresented = true
            }
        }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: FileIngestor.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if urls.isEmpty { dismiss() } else { model.start(urls: urls) }
            case .failure:
                dismiss()
            }
        }
        // D5 — the demoted wizard, reachable ONLY from the report's fix-mapping hatch.
        .fullScreenCover(isPresented: $showWizard) {
            ImportWizardView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .processing:
            processing(titleKey: "import.processing")
        case .report:
            if let _ = model.report {
                UnderstandingReportView(
                    report: reportBinding,
                    onConfirm: { model.confirm() },
                    onCancel: { dismiss() },
                    onFixMapping: { _ in showWizard = true }   // D5 escape hatch
                )
            } else {
                processing(titleKey: "import.processing")
            }
        case .executing:
            processing(titleKey: "import.executing", fraction: model.progress.fraction)
        case .done:
            summary
        }
    }

    @ViewBuilder
    private func processing(titleKey: LocalizedStringKey, fraction: Double? = nil) -> some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 220)
            } else {
                ProgressView().progressViewStyle(.circular)
            }
            Text(titleKey).font(.subheadline).foregroundStyle(Palette.secondaryInk)
        }
        .tint(Palette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("import.processing")
    }

    private var summary: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Palette.accent)
            Text("import.summary.done \(model.importedCount)").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .accessibilityIdentifier("import.summary.doneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("import.summary")
    }

    // MARK: - Bindings

    private var reportBinding: Binding<UnderstandingReport> {
        Binding(get: { model.report ?? UnderstandingReport(files: [], duplicateDraftIDs: [], negativesFound: false, decisions: ReportDecisions(), importDate: Date()) },
                set: { model.report = $0 })
    }
}

/// In-code synthetic files for the UI-test report seam (`-importReportUITest`):
/// a Family-B-shaped CSV (preamble + debit/credit + counterparty) and a generic
/// CSV (asks a context question), so the report renders both a family ✓ and a
/// generic ⚠ with a question.
enum ImportUITestFixtures {
    static var inputs: [ImportInput] {
        let familyB = """
        Data generare extras:,25/02/22
        Numar client:,0000000000
        Cod BIC Raiffeisen Bank:,RZBRROBU

        Data inregistrare,Data tranzactiei,Suma debit,Suma credit,Nume/Denumire ordonator/beneficiar,Descrierea tranzactiei
        28/01/2022,28/01/2022,1400,,FirmaA,plata materiale
        31/01/2022,31/01/2022,,615.28,PersoanaB,INCASARE transfer
        15/02/2022,15/02/2022,800,,,SCHIMB VALUTAR
        """
        let generic = """
        Data,Suma,Descriere,Categorie
        15.03.2024,120,Benzina OMV,Combustibil
        16.03.2024,45.50,Cafea,Restaurant
        """
        return [
            ImportInput(data: Data(familyB.utf8), fileName: "extras.csv"),
            ImportInput(data: Data(generic.utf8), fileName: "cheltuieli.csv"),
        ]
    }
}
