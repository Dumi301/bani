import Foundation
import UniformTypeIdentifiers
import UIKit

/// A picked file after the reading ladder has run (D1): either a tabular grid
/// (xlsx/csv → the family/generic path) or a document's text (pdf/docx/image →
/// the understanding path), or an explained failure. `Sendable` so it crosses the
/// import actor boundary.
enum IngestedContent: Sendable, Equatable {
    case tabular(RawDocument)
    case document(text: String, usedOCR: Bool)
    case unreadable(UnreadableReason)
}

enum UnreadableReason: String, Sendable, Equatable {
    case emptyOrCorrupt
    case noTextFound       // a document we opened but found no readable text in
    case unsupportedType

    var messageKey: String {
        switch self {
        case .emptyOrCorrupt: "import.unreadable.corrupt"
        case .noTextFound: "import.unreadable.noText"
        case .unsupportedType: "import.unreadable.unsupported"
        }
    }
}

struct IngestedFile: Sendable, Equatable {
    var fileName: String
    var content: IngestedContent
}

/// The single entry point that turns picked bytes into an `IngestedFile`. Sniffs
/// the kind by extension then magic bytes, and dispatches down the reading ladder.
/// Pure/throwing-free and non-isolated — runs off the main actor.
enum FileIngestor {

    /// All content types the one-tap `fileImporter` accepts (D1). Multi-select.
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .pdf, .png, .jpeg, .heic]
        for ext in ["xlsx", "docx"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if let heic = UTType("public.heic") { types.append(heic) }
        return types
    }

    enum Kind { case xlsx, csv, pdf, docx, image, unknown }

    static func kind(fileName: String, data: Data) -> Kind {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".xlsx") { return .xlsx }
        if lower.hasSuffix(".docx") { return .docx }
        if lower.hasSuffix(".csv") || lower.hasSuffix(".txt") { return .csv }
        if lower.hasSuffix(".pdf") { return .pdf }
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".heic") || lower.hasSuffix(".heif") { return .image }
        // Magic-byte sniff.
        if data.count >= 4 {
            if data[0] == 0x25, data[1] == 0x50, data[2] == 0x44, data[3] == 0x46 { return .pdf }      // %PDF
            if data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 {                     // PK zip
                // docx and xlsx are both zips; disambiguate by a marker path.
                if containsZipEntry(suffix: "word/document.xml", in: data) { return .docx }
                return .xlsx
            }
            if data[0] == 0xFF, data[1] == 0xD8 { return .image }                                        // JPEG
            if data[0] == 0x89, data[1] == 0x50 { return .image }                                        // PNG
        }
        return .csv
    }

    private static func containsZipEntry(suffix: String, in data: Data) -> Bool {
        MinimalZip.extract(entrySuffix: suffix, from: data) != nil
    }

    /// Read raw bytes into an `IngestedFile`. Never throws.
    static func ingest(data: Data, fileName: String) -> IngestedFile {
        let content: IngestedContent
        switch kind(fileName: fileName, data: data) {
        case .xlsx:
            content = (try? XLSXReader.parseRaw(data: data, fileName: fileName)).map(IngestedContent.tabular) ?? .unreadable(.emptyOrCorrupt)
        case .csv:
            content = (try? CSVParser.parseRaw(data: data, fileName: fileName)).map(IngestedContent.tabular) ?? .unreadable(.emptyOrCorrupt)
        case .pdf:
            if let r = PdfImportReader.read(data: data), !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content = .document(text: r.text, usedOCR: r.usedOCR)
            } else {
                content = .unreadable(.noTextFound)
            }
        case .docx:
            if let text = DocxReader.extractText(from: data), !text.isEmpty {
                content = .document(text: text, usedOCR: false)
            } else {
                content = .unreadable(.emptyOrCorrupt)
            }
        case .image:
            if let image = UIImageFromData(data), let text = OCRService.recognize(image), !text.isEmpty {
                content = .document(text: text, usedOCR: true)
            } else {
                content = .unreadable(.noTextFound)
            }
        case .unknown:
            content = .unreadable(.unsupportedType)
        }
        return IngestedFile(fileName: fileName, content: content)
    }

    /// Read a security-scoped picked URL.
    static func ingest(url: URL) -> IngestedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return IngestedFile(fileName: url.lastPathComponent, content: .unreadable(.emptyOrCorrupt))
        }
        return ingest(data: data, fileName: url.lastPathComponent)
    }
}

/// `UIImage(data:)` wrapped so callers stay uniform.
private func UIImageFromData(_ data: Data) -> UIImage? { UIImage(data: data) }
