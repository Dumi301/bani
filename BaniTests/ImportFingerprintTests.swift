import XCTest
@testable import Bani

/// Batch-level dedup fingerprints + the ≥80% re-import warning threshold (D).
final class ImportFingerprintTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testFingerprintIgnoresTimeAndDescriptionCasing() {
        let a = ImportFingerprint.fingerprint(date: date(2024, 3, 15, hour: 9), amount: Decimal(50), description: "Lidl  Cluj")
        let b = ImportFingerprint.fingerprint(date: date(2024, 3, 15, hour: 18), amount: Decimal(50), description: "lidl cluj")
        XCTAssertEqual(a, b)   // same day + amount + normalized description
    }

    func testFingerprintDistinguishesAmountAndDay() {
        let base = ImportFingerprint.fingerprint(date: date(2024, 3, 15), amount: Decimal(50), description: "x")
        XCTAssertNotEqual(base, ImportFingerprint.fingerprint(date: date(2024, 3, 16), amount: Decimal(50), description: "x"))
        XCTAssertNotEqual(base, ImportFingerprint.fingerprint(date: date(2024, 3, 15), amount: Decimal(51), description: "x"))
    }

    func testOverlapThreshold() {
        let incoming = (0..<10).map { "fp\($0)" }
        let eightExisting = Set(incoming.prefix(8))
        XCTAssertEqual(ImportFingerprint.overlapRatio(incoming: incoming, existing: eightExisting), 0.8, accuracy: 0.0001)
        XCTAssertTrue(ImportFingerprint.looksAlreadyImported(incoming: incoming, existing: eightExisting))

        let sevenExisting = Set(incoming.prefix(7))
        XCTAssertFalse(ImportFingerprint.looksAlreadyImported(incoming: incoming, existing: sevenExisting))
    }

    func testEmptyIncomingIsNotFlagged() {
        XCTAssertFalse(ImportFingerprint.looksAlreadyImported(incoming: [], existing: ["a"]))
        XCTAssertEqual(ImportFingerprint.overlapRatio(incoming: [], existing: ["a"]), 0)
    }
}
