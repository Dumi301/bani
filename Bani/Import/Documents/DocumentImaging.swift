import Foundation
import PDFKit
import Vision
import UIKit

/// PDF text-layer vs OCR routing decision (D1) — pure, so it is unit-tested
/// without Vision: a PDF with a real text layer reads that layer; a scanned PDF
/// (no/low text) is rasterized and OCR'd.
enum PdfRouting {
    /// A text layer with at least this many non-whitespace characters is trusted
    /// as real text; below it the page is treated as scanned → OCR.
    static let minTextLayerChars = 20
    static func usesOCR(textLayerCharacters: Int) -> Bool { textLayerCharacters < minTextLayerChars }
}

/// Reads a PDF to text: the embedded text layer when present, else rasterize +
/// Vision OCR (RO+EN). Returns the text and whether OCR was used (surfaced in the
/// report). Non-isolated so it runs off the main actor.
enum PdfImportReader {
    struct Result: Sendable, Equatable { var text: String; var usedOCR: Bool }

    static func read(data: Data) -> Result? {
        guard let doc = PDFDocument(data: data) else { return nil }
        var layer = ""
        for i in 0..<doc.pageCount { layer += (doc.page(at: i)?.string ?? "") + "\n" }
        let significant = layer.filter { !$0.isWhitespace }.count
        if !PdfRouting.usesOCR(textLayerCharacters: significant) {
            return Result(text: layer, usedOCR: false)
        }
        // Scanned → rasterize each page + OCR.
        var ocr = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let image = rasterize(page) else { continue }
            if let t = OCRService.recognize(image) { ocr += t + "\n" }
        }
        return Result(text: ocr, usedOCR: true)
    }

    static func rasterize(_ page: PDFPage, scale: CGFloat = 2) -> UIImage? {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }
}

/// Vision text recognition (D1). Requests Romanian + English when the runtime
/// supports them (checked via `supportedRecognitionLanguages`), else falls back to
/// the automatic language set — a note the pipeline surfaces in the report.
enum OCRService {
    /// The languages actually requested for the last/any run (for the report note).
    static func requestedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return resolveLanguages(for: request)
    }

    static func recognize(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let langs = resolveLanguages(for: request)
        if !langs.isEmpty { request.recognitionLanguages = langs }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let observations = request.results ?? []
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func resolveLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        var out: [String] = []
        for preferred in ["ro-RO", "ro", "en-US", "en"] where supported.contains(preferred) && !out.contains(preferred) {
            out.append(preferred)
        }
        return out   // empty → Vision uses its automatic default
    }
}
