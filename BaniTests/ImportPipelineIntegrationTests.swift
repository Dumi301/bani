import XCTest
import SwiftData
import UIKit
@testable import Bani

/// End-to-end import coverage: report states from the pipeline, cross-batch dedup,
/// the attachment round-trip (import → file+row exist → undo → both gone), docx XML
/// extraction, PDF text-vs-OCR routing, and the demoted wizard's header-row picker.
final class ImportPipelineIntegrationTests: XCTestCase {

    private final class Anchor {}

    private let genericCSV = """
    Data,Suma,Descriere,Categorie
    15.03.2024,120,Benzina OMV,Combustibil
    16.03.2024,45.50,Cafea,Restaurant
    """

    // MARK: - Report states (F)

    func testReportStatesFamilyAndGeneric() async throws {
        let report = await ImportPipeline.buildReport(
            inputs: ImportUITestFixtures.inputs, existingFingerprints: [],
            importDate: Date(), extractor: HeuristicExtractor()
        )
        XCTAssertEqual(report.files.count, 2)

        let bFile = try XCTUnwrap(report.files.first { $0.fileName == "extras.csv" })
        XCTAssertGreaterThan(bFile.importedCount, 0)
        XCTAssertFalse(bFile.needsContextChoice, "family file needs no context question")
        XCTAssertEqual(bFile.appliedContext, .work, "H1 — Family B defaults to Work")
        XCTAssertEqual(bFile.drafts.filter { $0.direction == .income }.count, 1, "credit row imported as income")

        let gFile = try XCTUnwrap(report.files.first { $0.fileName == "cheltuieli.csv" })
        XCTAssertTrue(gFile.needsContextChoice, "H1 — a generic file asks a context question")
    }

    // MARK: - Cross-batch dedup (D4)

    func testCrossBatchDedupDefaultSkip() async throws {
        let inputs = [ImportInput(data: Data(genericCSV.utf8), fileName: "g.csv")]
        let first = await ImportPipeline.buildReport(inputs: inputs, existingFingerprints: [], importDate: Date(), extractor: HeuristicExtractor())
        let drafts = first.files.flatMap(\.drafts)
        XCTAssertGreaterThan(drafts.count, 0)

        // Re-import with one row's fingerprint already present.
        let dupFP = drafts[0].fingerprint
        let second = await ImportPipeline.buildReport(inputs: inputs, existingFingerprints: [dupFP], importDate: Date(), extractor: HeuristicExtractor())
        XCTAssertGreaterThanOrEqual(second.duplicateCount, 1, "the re-imported row is flagged a duplicate")
        // Default skip → committable excludes the duplicate.
        XCTAssertEqual(second.committableDrafts.count, drafts.count - second.duplicateCount)
    }

    // MARK: - Attachment round-trip (E2)

    func testAttachmentRoundTrip() async throws {
        let container = try await MainActor.run { try ImportTestSupport.inMemoryContainer() }
        let draft = DraftTransaction(date: Date(), amount: 500, currency: .ron, direction: .expense,
                                     descriptionText: "Contract", context: .personal, category: .byDescription, sourceRow: 0)
        let attachment = PendingAttachment(originalData: Data("PDFBYTES".utf8), originalFileName: "contract.pdf", extractedText: "extracted text", summary: "A rental contract.")
        let item = CommitItem(draft: draft, context: .personal, attachment: attachment)

        let runner = ImportCommitRunner(modelContainer: container)
        let outcome = await runner.commit(items: [item], fileName: "contract.pdf", contextChoice: "personal", notes: "", skippedCount: 0, onProgress: { _ in })
        guard case let .completed(batchID, imported) = outcome else { return XCTFail("expected completed") }
        XCTAssertEqual(imported, 1)

        let tx = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Transaction>()).first)
        let attID = try XCTUnwrap(tx.attachmentID, "imported document row carries an attachmentID")
        XCTAssertEqual(tx.direction, .expense)
        XCTAssertNotNil(AttachmentStore.originalURL(id: attID), "the original file exists after import")
        XCTAssertEqual(AttachmentStore.summary(id: attID), "A rental contract.")

        // Undo the batch → the row AND the stored file are gone.
        await MainActor.run { ImportBatchStore.undo(batchID: batchID, in: ModelContext(container)) }
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Transaction>()).count, 0)
        XCTAssertNil(AttachmentStore.originalURL(id: attID), "the attachment file is deleted on batch undo")
    }

    // MARK: - docx XML extraction (D1)

    func testDocxExtraction() throws {
        guard let url = Bundle(for: Anchor.self).url(forResource: "contract-sample", withExtension: "docx"),
              let data = try? Data(contentsOf: url) else { throw XCTSkip("contract-sample.docx not bundled") }
        XCTAssertEqual(FileIngestor.kind(fileName: "contract-sample.docx", data: data), .docx)
        let text = try XCTUnwrap(DocxReader.extractText(from: data), "unzip + WordML extraction")
        XCTAssertTrue(text.contains("CONTRACT DE INCHIRIERE"))
        XCTAssertTrue(text.contains("Chirie 1200 lei"))

        if case .document(let t, let usedOCR) = FileIngestor.ingest(data: data, fileName: "contract-sample.docx").content {
            XCTAssertFalse(usedOCR)
            XCTAssertTrue(t.contains("1200"))
        } else { XCTFail("docx should ingest as a document") }
    }

    func testDocxWordMLDirect() {
        let xml = "<w:p><w:r><w:t>Line A</w:t></w:r></w:p><w:p><w:r><w:t>Line B</w:t></w:r></w:p>"
        let text = DocxReader.textFromWordML(xml)
        XCTAssertTrue(text.contains("Line A"))
        XCTAssertTrue(text.contains("Line B"))
        XCTAssertTrue(text.contains("\n"), "paragraphs become newlines")
    }

    // MARK: - PDF text-vs-OCR routing (D1)

    func testPdfTextLayerRouting() throws {
        // The routing decision is pure.
        XCTAssertFalse(PdfRouting.usesOCR(textLayerCharacters: 100))
        XCTAssertTrue(PdfRouting.usesOCR(textLayerCharacters: 3))

        // A drawn text-layer PDF reads its text (NOT OCR).
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            ("INVOICE Total: 1200 EUR pentru servicii prestate." as NSString)
                .draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let result = try XCTUnwrap(PdfImportReader.read(data: data))
        XCTAssertFalse(result.usedOCR, "a text-layer PDF is read directly, not scanned")
        XCTAssertTrue(result.text.contains("INVOICE"))
    }

    // MARK: - Wizard escape hatch: header-row picker (D5, bug #2 fallback)

    @MainActor
    func testWizardHeaderRowPicker() {
        let model = ImportWizardModel()
        // The auto-detected header lands on a preamble line; the real header is a
        // later row. The picker promotes it and the mapping completes.
        let sheet = TabularSheet(id: "s", name: "s", headers: ["Titlu preambul", "", ""], rows: [
            SheetRow(cells: [SheetCell(text: "Data"), SheetCell(text: "Suma"), SheetCell(text: "Descriere")], sourceRow: 2),
            SheetRow(cells: [SheetCell(text: "15.03.2024"), SheetCell(text: "120"), SheetCell(text: "benzina")], sourceRow: 3),
        ])
        model.selectSheet(sheet)
        XCTAssertGreaterThan(model.maxHeaderRow, 0, "the header-row picker is reachable")
        model.applyHeaderRow(1)
        XCTAssertEqual(model.headerRowIndex, 1)
        XCTAssertTrue(model.mapping.isComplete, "promoting the real header row recovers the mapping")
    }
}
