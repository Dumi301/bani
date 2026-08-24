import Foundation

/// A tiny STORE-only ZIP writer — the inverse of the proven read-only `MinimalZip`
/// extractor (`Bani/Import/Documents/MinimalZip.swift`), whose central-directory /
/// local-header byte layout this mirrors exactly. Every entry is written with
/// compression method 0 (stored, verbatim) plus a correct CRC-32, so the archive
/// is a spec-valid ZIP that `MinimalZip.extract` reads back byte-for-byte AND that
/// ZIPFoundation (the reader behind CoreXLSX) opens without complaint. That dual
/// readability is what lets `XLSXWriter` round-trip an exported `.xlsx` through the
/// existing `XLSXReader` import path (`RaportExportTests`).
///
/// Store-only (no DEFLATE) is deliberate: a spreadsheet export is small, and a
/// verbatim payload keeps the writer auditable and dependency-free. The type is
/// intentionally self-contained and generic over `(path, data)` entries so a later
/// phase can lift it into a shared package writer (e.g. the parked backup module's
/// `.banizip` writer) without change — it knows nothing about XLSX.
enum StoreZipWriter {

    /// One archive member: a full in-archive path (e.g. `xl/worksheets/sheet1.xml`)
    /// and its raw bytes. Paths use forward slashes (the ZIP convention).
    struct Entry {
        let path: String
        let data: Data
    }

    /// Serialise `entries` into a complete, valid ZIP archive (local headers →
    /// central directory → end-of-central-directory). Entry order is preserved.
    static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        // (offset-of-local-header, name-bytes, crc, size) captured for the central dir.
        var records: [(offset: UInt32, name: [UInt8], crc: UInt32, size: UInt32)] = []

        // Fixed, valid DOS date/time: 1980-01-01 00:00 (day 1, month 1 → 0x0021).
        let dosTime: UInt16 = 0x0000
        let dosDate: UInt16 = 0x0021

        // ── Local file headers + data ──
        for entry in entries {
            let nameBytes = [UInt8](entry.path.utf8)
            let payload = [UInt8](entry.data)
            let crc = CRC32.checksum(payload)
            let size = UInt32(payload.count)
            let offset = UInt32(out.count)

            out.appendU32(0x0403_4b50)          // local file header signature
            out.appendU16(20)                    // version needed to extract (2.0)
            out.appendU16(0)                     // general purpose bit flag
            out.appendU16(0)                     // compression method: 0 = stored
            out.appendU16(dosTime)               // last mod time
            out.appendU16(dosDate)               // last mod date
            out.appendU32(crc)                   // CRC-32
            out.appendU32(size)                  // compressed size (== uncompressed)
            out.appendU32(size)                  // uncompressed size
            out.appendU16(UInt16(nameBytes.count)) // file name length
            out.appendU16(0)                     // extra field length
            out.append(contentsOf: nameBytes)    // file name
            out.append(contentsOf: payload)      // file data (stored verbatim)

            records.append((offset, nameBytes, crc, size))
        }

        // ── Central directory ──
        let cdStart = UInt32(out.count)
        for record in records {
            out.appendU32(0x0201_4b50)          // central file header signature
            out.appendU16(20)                    // version made by
            out.appendU16(20)                    // version needed to extract
            out.appendU16(0)                     // general purpose bit flag
            out.appendU16(0)                     // compression method: 0 = stored
            out.appendU16(dosTime)               // last mod time
            out.appendU16(dosDate)               // last mod date
            out.appendU32(record.crc)            // CRC-32
            out.appendU32(record.size)           // compressed size
            out.appendU32(record.size)           // uncompressed size
            out.appendU16(UInt16(record.name.count)) // file name length
            out.appendU16(0)                     // extra field length
            out.appendU16(0)                     // file comment length
            out.appendU16(0)                     // disk number start
            out.appendU16(0)                     // internal file attributes
            out.appendU32(0)                     // external file attributes
            out.appendU32(record.offset)         // relative offset of local header
            out.append(contentsOf: record.name)  // file name
        }
        let cdSize = UInt32(out.count) - cdStart

        // ── End of central directory ──
        out.appendU32(0x0605_4b50)              // EOCD signature
        out.appendU16(0)                         // number of this disk
        out.appendU16(0)                         // disk with the CD start
        out.appendU16(UInt16(records.count))     // CD entries on this disk
        out.appendU16(UInt16(records.count))     // total CD entries
        out.appendU32(cdSize)                    // size of the central directory
        out.appendU32(cdStart)                   // offset of CD start
        out.appendU16(0)                         // comment length

        return out
    }
}

// MARK: - CRC-32 (reflected, polynomial 0xEDB88320 — the ZIP/zlib standard)

/// Standard reflected CRC-32 (the same checksum ZIPFoundation validates on read),
/// computed with a lazily-built lookup table.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian append helpers (mirror MinimalZip's little-endian readers)

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
