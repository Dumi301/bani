import Foundation
import UniformTypeIdentifiers

/// The single entry point the wizard calls after a file is picked: resolve the
/// URL to bytes (security-scoped), sniff the kind, and dispatch to the CSV or
/// XLSX reader. Pure/throwing and isolation-free so it runs off the main actor.
enum DocumentReader {

    /// The content types the `fileImporter` is limited to (C1): .csv + .xlsx.
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let csv = UTType(filenameExtension: "csv"), !types.contains(csv) { types.append(csv) }
        return types
    }

    /// Read a picked file URL into a `TabularDocument`. Handles the security-scoped
    /// resource lifecycle the document picker hands back.
    static func read(url: URL) throws -> TabularDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try read(data: data, fileName: url.lastPathComponent)
    }

    /// Read raw bytes with a known file name (the unit-test seam — no file I/O).
    static func read(data: Data, fileName: String) throws -> TabularDocument {
        switch kind(fileName: fileName, data: data) {
        case .xlsx: return try XLSXReader.parse(data: data, fileName: fileName)
        case .csv:  return try CSVParser.parse(data: data, fileName: fileName)
        }
    }

    /// Decide the kind by extension first, then by magic bytes (a zip header
    /// "PK\03\04" means an OOXML .xlsx; anything else is treated as CSV/text).
    static func kind(fileName: String, data: Data) -> ImportFileKind {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".xlsx") { return .xlsx }
        if lower.hasSuffix(".csv") || lower.hasSuffix(".txt") { return .csv }
        if data.count >= 4, data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 {
            return .xlsx
        }
        return .csv
    }
}
