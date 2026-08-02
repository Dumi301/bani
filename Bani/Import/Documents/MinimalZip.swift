import Foundation
import Compression

/// A tiny read-only ZIP extractor — just enough to pull `word/document.xml` out of
/// a `.docx` (D1: "docx → unzip + parse natively, no new dependency"). Parses the
/// central directory, then inflates the target entry's raw DEFLATE via Apple's
/// `Compression` framework (`COMPRESSION_ZLIB` decodes raw deflate, which is what
/// ZIP stores). Stored (method 0) entries are copied verbatim.
enum MinimalZip {

    /// Extract the bytes of the first entry whose name ends with `suffix`
    /// (e.g. "word/document.xml"). Returns `nil` on any structural problem —
    /// callers degrade to an "unreadable document" report chip, never a crash.
    static func extract(entrySuffix suffix: String, from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { return nil }
        let cdCount = readU16(bytes, eocd + 10)
        var cdOffset = Int(readU32(bytes, eocd + 16))

        for _ in 0..<cdCount {
            guard cdOffset + 46 <= bytes.count, readU32(bytes, cdOffset) == 0x02014b50 else { return nil }
            let method = readU16(bytes, cdOffset + 10)
            let compSize = Int(readU32(bytes, cdOffset + 20))
            let uncompSize = Int(readU32(bytes, cdOffset + 24))
            let fnLen = Int(readU16(bytes, cdOffset + 28))
            let extraLen = Int(readU16(bytes, cdOffset + 30))
            let commentLen = Int(readU16(bytes, cdOffset + 32))
            let localOffset = Int(readU32(bytes, cdOffset + 42))
            let nameStart = cdOffset + 46
            guard nameStart + fnLen <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<nameStart + fnLen], as: UTF8.self)

            if name.hasSuffix(suffix) {
                return readEntry(bytes, localOffset: localOffset, method: method, compSize: compSize, uncompSize: uncompSize)
            }
            cdOffset = nameStart + fnLen + extraLen + commentLen
        }
        return nil
    }

    private static func readEntry(_ bytes: [UInt8], localOffset: Int, method: Int, compSize: Int, uncompSize: Int) -> Data? {
        guard localOffset + 30 <= bytes.count, readU32(bytes, localOffset) == 0x04034b50 else { return nil }
        let fnLen = Int(readU16(bytes, localOffset + 26))
        let extraLen = Int(readU16(bytes, localOffset + 28))
        let dataStart = localOffset + 30 + fnLen + extraLen
        guard dataStart + compSize <= bytes.count else { return nil }
        let comp = Array(bytes[dataStart..<dataStart + compSize])

        if method == 0 { return Data(comp) }              // stored
        guard method == 8 else { return nil }             // only deflate supported
        return inflate(comp, expected: uncompSize)
    }

    /// Raw-DEFLATE inflate via `Compression`. Grows the destination if the declared
    /// uncompressed size was zero/short.
    private static func inflate(_ comp: [UInt8], expected: Int) -> Data? {
        var capacity = expected > 0 ? expected : max(comp.count * 4, 16_384)
        for _ in 0..<6 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written = comp.withUnsafeBufferPointer { src in
                dst.withUnsafeMutableBufferPointer { d in
                    compression_decode_buffer(d.baseAddress!, capacity, src.baseAddress!, comp.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && (written < capacity || written == expected) {
                return Data(dst[0..<written])
            }
            if written == capacity { capacity *= 2; continue }   // filled exactly — may be truncated
            if written > 0 { return Data(dst[0..<written]) }
            return nil
        }
        return nil
    }

    // MARK: - Little-endian readers

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var i = bytes.count - 22
        let lowerBound = max(0, bytes.count - 22 - 65_536)
        while i >= lowerBound {
            if readU32(bytes, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func readU16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 1 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o + 1]) << 8)
    }
    private static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

/// Extracts plain text from a `.docx` by unzipping `word/document.xml` and
/// stripping the WordprocessingML tags (paragraphs → newlines, tabs → tabs,
/// XML entities decoded). No dependency (D1).
enum DocxReader {
    static func extractText(from data: Data) -> String? {
        guard let xml = MinimalZip.extract(entrySuffix: "word/document.xml", from: data) else { return nil }
        let raw = String(decoding: xml, as: UTF8.self)
        return textFromWordML(raw)
    }

    static func textFromWordML(_ xml: String) -> String {
        var s = xml
        // Paragraph + line breaks → newlines; tabs → tabs.
        for (tag, repl) in [("</w:p>", "\n"), ("<w:br/>", "\n"), ("<w:br />", "\n"), ("<w:tab/>", "\t"), ("<w:tab />", "\t")] {
            s = s.replacingOccurrences(of: tag, with: repl)
        }
        // Strip every remaining tag.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode the common XML entities.
        s = s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        // Numeric entities.
        s = decodeNumericEntities(s)
        // Collapse runs of blank lines.
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#"), let re = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return s }
        let ns = s as NSString
        var result = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let token = ns.substring(with: m.range(at: 1))
            let scalarValue: UInt32?
            if token.hasPrefix("x") { scalarValue = UInt32(token.dropFirst(), radix: 16) }
            else { scalarValue = UInt32(token) }
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                result = (result as NSString).replacingCharacters(in: m.range, with: String(scalar))
            }
        }
        return result
    }
}
