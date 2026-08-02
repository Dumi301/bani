import Foundation

/// One picked file's bytes.
struct ImportInput: Sendable, Equatable {
    var data: Data
    var fileName: String
}

/// Builds the `UnderstandingReport` from picked files (D2 + F). Ingests each file
/// down the reading ladder, classifies tabular sheets by family signature, parses
/// with the hardcoded family parsers (or the generic path), runs the document
/// understanding seam for documents, and cross-batch-dedups every draft. Nothing
/// is written — the report is a projection the user confirms. `async` (documents
/// use the async understanding seam); non-isolated so it runs off the main actor.
enum ImportPipeline {

    static func buildReport(
        inputs: [ImportInput],
        existingFingerprints: Set<String>,
        importDate: Date,
        extractor: any DocumentUnderstanding
    ) async -> UnderstandingReport {
        var files: [FileReport] = []
        var negativesFound = false

        for input in inputs {
            let ingested = FileIngestor.ingest(data: input.data, fileName: input.fileName)
            switch ingested.content {
            case .tabular(let doc):
                let (report, negatives) = tabularReport(doc: doc, fileName: input.fileName)
                negativesFound = negativesFound || negatives
                files.append(report)
            case .document(let text, let usedOCR):
                let report = await documentReport(text: text, usedOCR: usedOCR, input: input, importDate: importDate, extractor: extractor)
                files.append(report)
            case .unreadable(let reason):
                files.append(FileReport(
                    fileName: input.fileName, status: .failed, isDocument: false, usedOCR: false,
                    unreadableReasonKey: reason.messageKey, sheets: [], drafts: [], skippedCount: 0,
                    noteKeys: [reason.messageKey], needsContextChoice: false,
                    appliedContext: .personal, canFixMapping: false, extraction: nil, attachment: nil
                ))
            }
        }

        // D4 — cross-batch row-level dedup: mark drafts already present in prior imports.
        var duplicates: Set<UUID> = []
        for file in files {
            for draft in file.drafts where existingFingerprints.contains(draft.fingerprint) {
                duplicates.insert(draft.id)
            }
        }

        return UnderstandingReport(
            files: files, duplicateDraftIDs: duplicates, negativesFound: negativesFound,
            decisions: ReportDecisions(), importDate: importDate
        )
    }

    // MARK: - Tabular

    private static func tabularReport(doc: RawDocument, fileName: String) -> (FileReport, Bool) {
        // Classify every sheet up front (single pass — bug #5).
        let roles = doc.sheets.map { ($0, FamilyDetection.classify($0)) }
        let families: [ImportFamily] = roles.compactMap { if case .transactions(let f, _) = $0.1 { return f } else { return nil } }
        let fileFamily = families.first
        let hasTransactions = fileFamily != nil
        let fileContext: TransactionContext = fileFamily == .d ? .personal : .work

        var drafts: [DraftTransaction] = []
        var sheets: [SheetSummary] = []
        var skipped = 0
        var negatives = false

        for (sheet, role) in roles {
            switch role {
            case .transactions(let family, let headerRow):
                let outcome = FamilyParser.parse(sheet: sheet, family: family, headerRow: headerRow)
                drafts += outcome.drafts
                skipped += outcome.skipped.count
                negatives = negatives || outcome.negativesFound
                sheets.append(SheetSummary(name: sheet.name ?? fileName, roleLabelKey: roleKey(family),
                                           importedCount: outcome.drafts.count, skippedCount: outcome.skipped.count, noteKeys: []))
            case .generic:
                // A generic sheet inside a workbook: parse generically, using the
                // file family's context if this is otherwise a family file.
                let outcome = GenericSheetImport.run(sheet, context: hasTransactions ? fileContext : .personal)
                drafts += outcome.drafts
                skipped += outcome.skippedCount
                sheets.append(SheetSummary(name: sheet.name ?? fileName, roleLabelKey: "import.role.generic",
                                           importedCount: outcome.drafts.count, skippedCount: outcome.skippedCount, noteKeys: outcome.noteKeys))
            case .skipped(let reason):
                sheets.append(SheetSummary(name: sheet.name ?? fileName, roleLabelKey: "import.role.skipped",
                                           importedCount: 0, skippedCount: 0, noteKeys: [reason.noteKey]))
            }
        }

        let isGenericFile = !hasTransactions && sheets.contains { $0.roleLabelKey == "import.role.generic" }
        let allSkipped = drafts.isEmpty && !sheets.isEmpty && sheets.allSatisfy { $0.roleLabelKey == "import.role.skipped" }
        let status: FileStatus = {
            if drafts.isEmpty { return .failed }
            if skipped > 0 { return .warning }
            return .ok
        }()
        var notes: [String] = sheets.flatMap(\.noteKeys)
        if allSkipped { notes.append("import.note.nonTransaction") }

        let report = FileReport(
            fileName: fileName, status: status, isDocument: false, usedOCR: false,
            unreadableReasonKey: allSkipped ? "import.unreadable.noTransactions" : nil,
            sheets: sheets, drafts: drafts, skippedCount: skipped, noteKeys: notes,
            needsContextChoice: isGenericFile, appliedContext: isGenericFile ? .personal : fileContext,
            canFixMapping: isGenericFile, extraction: nil, attachment: nil
        )
        return (report, negatives)
    }

    private static func roleKey(_ family: ImportFamily) -> String {
        switch family {
        case .a: "import.role.familyA"
        case .b: "import.role.familyB"
        case .c: "import.role.familyC"
        case .d: "import.role.familyD"
        }
    }

    // MARK: - Document

    private static func documentReport(text: String, usedOCR: Bool, input: ImportInput, importDate: Date, extractor: any DocumentUnderstanding) async -> FileReport {
        let extraction = await extractor.understand(text: text, fileName: input.fileName, importDate: importDate)
        var notes: [String] = []
        if usedOCR { notes.append("import.note.usedOCR") }

        guard extraction.hasUsableAmount, let amount = extraction.amount else {
            return FileReport(
                fileName: input.fileName, status: .failed, isDocument: true, usedOCR: usedOCR,
                unreadableReasonKey: "import.unreadable.noAmount", sheets: [], drafts: [], skippedCount: 0,
                noteKeys: notes + ["import.unreadable.noAmount"], needsContextChoice: false,
                appliedContext: .personal, canFixMapping: false, extraction: extraction, attachment: nil
            )
        }

        let draft = DraftTransaction(
            date: extraction.date ?? importDate, dateWasFallback: extraction.dateWasFallback,
            amount: amount, currency: extraction.currency, direction: extraction.direction,
            descriptionText: extraction.descriptionText.isEmpty ? extraction.docType.label : extraction.descriptionText,
            counterparty: extraction.counterparty, context: .personal, category: .byDescription,
            sourceRow: 0, confidence: extraction.overallConfidence, docSummary: extraction.summary
        )
        if extraction.dateWasFallback { notes.append("import.note.dateFallback") }
        let lowConfidence = extraction.overallConfidence < 0.6
        if lowConfidence { notes.append("import.note.lowConfidence") }
        let status: FileStatus = (extraction.dateWasFallback || lowConfidence) ? .warning : .ok

        let attachment = PendingAttachment(originalData: input.data, originalFileName: input.fileName,
                                           extractedText: text, summary: extraction.summary)
        return FileReport(
            fileName: input.fileName, status: status, isDocument: true, usedOCR: usedOCR,
            unreadableReasonKey: nil, sheets: [], drafts: [draft], skippedCount: 0,
            noteKeys: notes, needsContextChoice: true, appliedContext: .personal,
            canFixMapping: false, extraction: extraction, attachment: attachment
        )
    }
}
