import Foundation
import SwiftUI
import SwiftData

/// The steps of the import wizard (C1–C5).
enum ImportStep: Equatable {
    case intro
    case pickSheet
    case mapping
    case matchCategories
    case preview
    case executing
    case summary
}

/// Drives the whole import wizard on the main actor: reads the file, guesses the
/// mapping, validates rows, resolves category decisions, runs the background
/// import, and surfaces the undo. UI-state only — all parsing is delegated to the
/// pure `Import/` types and the SwiftData writes to `ImportRunner` /
/// `ImportBatchStore`.
@MainActor
@Observable
final class ImportWizardModel {

    // Injected once from the hosting view.
    var container: ModelContainer?
    var modelContext: ModelContext?
    /// Live custom categories + rule snapshots (from the view's @Query) for
    /// matching and preview categorization.
    var customCategories: [CustomCategorySnapshot] = []
    var ruleSnapshots: [CategoryRuleSnapshot] = []

    var step: ImportStep = .intro

    // File / sheet.
    var isReading = false
    var errorMessage: String?
    private(set) var document: TabularDocument?
    var selectedSheet: TabularSheet?

    // Mapping.
    var mapping = ImportFieldMapping()
    private(set) var dateAmbiguous = false

    // Validation.
    private(set) var parseResult: ImportParseResult?

    // Category resolution — keyed by the NORMALIZED category value.
    var categoryDecisions: [String: ImportCategoryDecision] = [:]
    private(set) var unmatchedCategoryValues: [String] = []

    // Execution.
    var progress = ImportProgress(processed: 0, total: 0)
    private(set) var outcome: ImportRunOutcome?
    private var importTask: Task<Void, Never>?
    var cancelledNotice = false

    // Dedup guard (D).
    var showDedupWarning = false

    var lookup: CustomCategoryLookup {
        var out: CustomCategoryLookup = [:]
        for c in customCategories { out[c.id] = c }
        return out
    }

    // MARK: - File loading

    func loadDocument(from url: URL) {
        errorMessage = nil
        isReading = true
        Task { [weak self] in
            // Read off the main actor; return a Sendable Result (map the error to a
            // localized message inside the detached task, since `any Error` isn't
            // Sendable).
            let result: Result<TabularDocument, String> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try DocumentReader.read(url: url))
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    return .failure(message)
                }
            }.value
            await MainActor.run {
                guard let self else { return }
                self.isReading = false
                switch result {
                case .success(let doc):
                    self.document = doc
                    if doc.sheets.count > 1 {
                        self.step = .pickSheet
                    } else if let sole = doc.sheets.first {
                        self.selectSheet(sole)
                    } else {
                        self.errorMessage = ImportReadError.noSheets.localizedDescription
                    }
                case .failure(let message):
                    self.errorMessage = message
                }
            }
        }
    }

    /// UI-test seam (`-importUITest`): load an in-code CSV directly, bypassing the
    /// system document picker (which a UI test can't drive), so the wizard can be
    /// exercised through to preview against a known fixture.
    func loadUITestFixture() {
        let csv = """
        Data,Suma,Descriere,Categorie
        15.03.2024,120,Benzina OMV,Combustibil
        16.03.2024,45.50,Cafea,Restaurant
        17.03.2024,250,Chirie,Utilitati
        """
        guard let doc = try? DocumentReader.read(data: Data(csv.utf8), fileName: "uitest.csv") else { return }
        document = doc
        if let sheet = doc.sheets.first { selectSheet(sheet) }
    }

    func selectSheet(_ sheet: TabularSheet) {
        selectedSheet = sheet
        guard !sheet.headers.isEmpty else {
            errorMessage = ImportReadError.emptyFile.localizedDescription
            return
        }
        mapping = HeaderGuesser.guess(headers: sheet.headers)
        detectDateFormat()
        refreshParse()
        step = .mapping
    }

    // MARK: - Mapping

    /// (Re)detect the date format from the mapped date column's samples.
    func detectDateFormat() {
        guard let sheet = selectedSheet, let dateColumn = mapping.dateColumn else {
            dateAmbiguous = false
            return
        }
        let samples = sheet.rows.compactMap { $0.cell(at: dateColumn) }
        let detection = DateFieldParser.detect(samples: samples)
        mapping.dateFormat = detection.format
        dateAmbiguous = detection.ambiguous
    }

    /// Re-run validation for the current mapping (pure, fast).
    func refreshParse() {
        guard let sheet = selectedSheet else { parseResult = nil; return }
        parseResult = ImportRowParser.parse(sheet: sheet, mapping: mapping)
    }

    var columnTitles: [String] { selectedSheet?.headers ?? [] }

    /// Advance from the mapping screen: finalize validation, auto-resolve category
    /// matches, and branch to the category-match step (if a category column has
    /// unmatched values) or straight to preview.
    func continueFromMapping() {
        refreshParse()
        buildCategoryDecisions()
        if mapping.usesCategoryColumn && !unmatchedCategoryValues.isEmpty {
            step = .matchCategories
        } else {
            step = .preview
        }
    }

    /// Auto-match every distinct category value; collect the leftovers for the user.
    private func buildCategoryDecisions() {
        categoryDecisions = [:]
        unmatchedCategoryValues = []
        guard mapping.usesCategoryColumn, let result = parseResult else { return }
        let matcher = CategoryMatcher(customCategories: customCategories)
        for value in result.distinctCategoryValues {
            let key = Categorizer.normalize(value)
            if let ref = matcher.match(value) {
                categoryDecisions[key] = .existing(ref)
            } else {
                unmatchedCategoryValues.append(value)
                // Default leftover decision: uncategorized until the user chooses.
                categoryDecisions[key] = .uncategorized
            }
        }
    }

    func decision(for value: String) -> ImportCategoryDecision {
        categoryDecisions[Categorizer.normalize(value)] ?? .uncategorized
    }

    func setDecision(_ decision: ImportCategoryDecision, for value: String) {
        categoryDecisions[Categorizer.normalize(value)] = decision
    }

    func finishCategoryMatching() {
        step = .preview
    }

    // MARK: - Preview helpers

    var previewRows: [ParsedImportRow] { Array((parseResult?.rows ?? []).prefix(10)) }
    var totalRowCount: Int { parseResult?.rows.count ?? 0 }
    var skippedRows: [SkippedImportRow] { parseResult?.skipped ?? [] }
    var skippedCount: Int { parseResult?.skipped.count ?? 0 }

    /// Preview display style for a row's category (resolves the pending decision).
    func previewStyle(for row: ParsedImportRow) -> CategoryStyle {
        switch row.categorySource {
        case .byDescription:
            let ref = Categorizer.categoryRef(for: row.descriptionText, rules: ruleSnapshots)
            return categoryStyle(ref, customs: lookup)
        case .uncategorized:
            return categoryStyle(nil, customs: lookup)
        case .columnValue(let value):
            switch categoryDecisions[Categorizer.normalize(value)] {
            case .existing(let ref):
                return categoryStyle(ref, customs: lookup)
            case .create(let name, let symbol, let colorIndex):
                return CategoryStyle(label: name, systemImage: symbol, color: CustomCategoryPalette.color(colorIndex))
            case .uncategorized, .none:
                return categoryStyle(nil, customs: lookup)
            }
        }
    }

    // MARK: - Import execution

    /// Context label stored on the batch + shown in the summary.
    var contextChoiceLabel: String {
        mapping.usesContextColumn ? String(localized: "import.context.fromColumn") : mapping.fixedContext.label
    }

    private var contextChoiceRaw: String {
        mapping.usesContextColumn ? "column" : mapping.fixedContext.rawValue
    }

    private var notesString: String {
        var parts: [String] = []
        if let name = selectedSheet?.name { parts.append("sheet=\(name)") }
        parts.append("dateFormat=\(mapping.dateFormat.rawValue)")
        if parseResult?.negativesFound == true { parts.append("negatives=\(mapping.negativesPolicy.rawValue)") }
        return parts.joined(separator: " · ")
    }

    /// Tapped "Import N rows". Runs the dedup guard first; if it trips, raise the
    /// advisory warning instead of importing.
    func requestImport() {
        guard let context = modelContext, let result = parseResult, !result.rows.isEmpty else { return }
        let incoming = result.rows.map(\.fingerprint)
        let existing = ImportBatchStore.existingImportFingerprints(in: context)
        if ImportFingerprint.looksAlreadyImported(incoming: incoming, existing: existing) {
            showDedupWarning = true
        } else {
            runImport()
        }
    }

    /// Proceed with the import despite the dedup warning (or after it passes).
    func runImport() {
        guard let container, let result = parseResult, !result.rows.isEmpty else { return }
        showDedupWarning = false
        cancelledNotice = false
        outcome = nil
        progress = ImportProgress(processed: 0, total: result.rows.count)
        step = .executing

        let rows = result.rows
        let decisions = categoryDecisions
        let fileName = document?.fileName ?? selectedSheet?.name ?? "import"
        let contextRaw = contextChoiceRaw
        let notes = notesString
        let skipped = result.skipped.count

        let progressHandler: @Sendable (ImportProgress) async -> Void = { [weak self] p in
            await MainActor.run { self?.progress = p }
        }

        importTask = Task { [weak self] in
            let runner = ImportRunner(modelContainer: container)
            let outcome = await runner.run(
                rows: rows, fileName: fileName, contextChoice: contextRaw,
                notes: notes, skippedCount: skipped, decisions: decisions,
                onProgress: progressHandler
            )
            await MainActor.run {
                guard let self else { return }
                self.outcome = outcome
                switch outcome {
                case .completed:
                    self.step = .summary
                case .cancelled:
                    self.cancelledNotice = true
                    self.step = .preview
                }
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    var importedCount: Int {
        if case let .completed(_, imported) = outcome { return imported }
        return 0
    }

    var completedBatchID: UUID? {
        if case let .completed(batchID, _) = outcome { return batchID }
        return nil
    }

    /// Undo the just-finished import from the summary screen.
    @discardableResult
    func undoCompletedImport() -> Int {
        guard let context = modelContext, let batchID = completedBatchID else { return 0 }
        let removed = ImportBatchStore.undo(batchID: batchID, in: context)
        outcome = nil
        return removed
    }
}
