import Foundation

/// On-disk store for imported-document attachments (E2). Each attached
/// transaction's original file + cached extraction text live under
/// `Application Support/ImportedDocuments/<attachmentID>/`. The detail view reads
/// them back for preview; deleting the transaction (or undoing its batch) deletes
/// the folder — files never outlive their row.
enum AttachmentStore {

    static var root: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ImportedDocuments", isDirectory: true)
    }

    private static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Persist a document's original bytes + extracted text under `id`. Returns
    /// `false` on any I/O failure (the transaction still imports, just without a
    /// previewable attachment).
    @discardableResult
    static func save(id: UUID, originalData: Data, originalFileName: String, extractedText: String, summary: String = "") -> Bool {
        let dir = folder(for: id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = (originalFileName as NSString).pathExtension
            let originalName = ext.isEmpty ? "original" : "original.\(ext)"
            try originalData.write(to: dir.appendingPathComponent(originalName))
            try Data(extractedText.utf8).write(to: dir.appendingPathComponent("extract.txt"))
            try Data(summary.utf8).write(to: dir.appendingPathComponent("summary.txt"))
            try Data(originalFileName.utf8).write(to: dir.appendingPathComponent("name.txt"))
            return true
        } catch {
            return false
        }
    }

    /// The stored 2–3 sentence extraction summary (shown beneath the preview, E2).
    static func summary(id: UUID) -> String? {
        let url = folder(for: id).appendingPathComponent("summary.txt")
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The original file URL for a QuickLook/PDFKit/image preview.
    static func originalURL(id: UUID) -> URL? {
        let dir = folder(for: id)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { $0.lastPathComponent.hasPrefix("original") }
    }

    /// The cached extraction/OCR text (shown beneath the preview).
    static func extractedText(id: UUID) -> String? {
        let url = folder(for: id).appendingPathComponent("extract.txt")
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The stored original file name.
    static func originalFileName(id: UUID) -> String? {
        let url = folder(for: id).appendingPathComponent("name.txt")
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Delete a single attachment folder.
    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Delete the attachments of a set of transactions (undo / batch-undo).
    static func delete(attachmentIDs: [UUID?]) {
        for case let id? in attachmentIDs { delete(id: id) }
    }
}
