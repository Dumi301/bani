import XCTest
@testable import Bani

/// Date-format detection (incl. the day/month ambiguity flag) and single-cell
/// parsing (noon normalization, time preservation, serial handling).
final class DateFieldParserTests: XCTestCase {

    private func cell(_ text: String, serial: Date? = nil) -> SheetCell {
        SheetCell(text: text, serialDate: serial)
    }
    private func comps(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    // MARK: - Detection

    func testDetectISO() {
        let d = DateFieldParser.detect(samples: [cell("2024-12-31"), cell("2024-01-05")])
        XCTAssertEqual(d.format, .iso)
        XCTAssertFalse(d.ambiguous)
    }

    func testDetectDayFirstDot() {
        let d = DateFieldParser.detect(samples: [cell("15.03.2024"), cell("16.03.2024")])
        XCTAssertEqual(d.format, .dayFirstDot)
        XCTAssertFalse(d.ambiguous)
    }

    func testDetectSlashAmbiguousDefaultsDayFirst() {
        // All components ≤ 12 → cannot tell day- from month-first.
        let d = DateFieldParser.detect(samples: [cell("05/03/2024"), cell("06/07/2024")])
        XCTAssertEqual(d.format, .dayFirstSlash)
        XCTAssertTrue(d.ambiguous)
    }

    func testDetectSlashMonthFirstProven() {
        // A second field > 12 proves month-first, unambiguously.
        let d = DateFieldParser.detect(samples: [cell("03/15/2024"), cell("07/22/2024")])
        XCTAssertEqual(d.format, .monthFirstSlash)
        XCTAssertFalse(d.ambiguous)
    }

    func testDetectSlashDayFirstProven() {
        let d = DateFieldParser.detect(samples: [cell("15/03/2024"), cell("22/07/2024")])
        XCTAssertEqual(d.format, .dayFirstSlash)
        XCTAssertFalse(d.ambiguous)
    }

    /// L1: dot-separated month-first evidence (second field > 12) must report the
    /// dedicated `.monthFirstDot` case, not `.monthFirstSlash` (the dead-ternary bug).
    func testDetectDotMonthFirstProven() {
        let d = DateFieldParser.detect(samples: [cell("03.15.2024"), cell("07.22.2024")])
        XCTAssertEqual(d.format, .monthFirstDot)
        XCTAssertFalse(d.ambiguous)
    }

    /// L1: `candidatePatterns` builds dot/slash/dash variants for whichever base
    /// pattern is picked, so `.monthFirstDot` parses byte-identically to
    /// `.monthFirstSlash` for the same dot-separated text — the fix is purely about
    /// which case `detect` reports, never about parse behavior.
    func testParseDotMonthFirstMatchesSlashMonthFirstBehavior() {
        let dotDate = try! XCTUnwrap(DateFieldParser.parse(cell: cell("03.15.2024"), format: .monthFirstDot))
        let slashDate = try! XCTUnwrap(DateFieldParser.parse(cell: cell("03.15.2024"), format: .monthFirstSlash))
        XCTAssertEqual(dotDate, slashDate)
        let c = comps(dotDate)
        XCTAssertEqual(c.month, 3); XCTAssertEqual(c.day, 15)
    }

    func testDetectSerialWhenXLSXCellsResolved() {
        let d = DateFieldParser.detect(samples: [cell("45657", serial: Date(timeIntervalSince1970: 0))])
        XCTAssertEqual(d.format, .excelSerial)
    }

    // MARK: - Parsing

    func testParseNoonNormalizationForDateOnly() {
        let date = try! XCTUnwrap(DateFieldParser.parse(cell: cell("15.03.2024"), format: .dayFirstDot))
        let c = comps(date)
        XCTAssertEqual(c.year, 2024); XCTAssertEqual(c.month, 3); XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 12); XCTAssertEqual(c.minute, 0)   // rows lacking a time → 12:00
    }

    func testParseKeepsExplicitTime() {
        let date = try! XCTUnwrap(DateFieldParser.parse(cell: cell("2024-03-15 09:30"), format: .iso))
        let c = comps(date)
        XCTAssertEqual(c.hour, 9); XCTAssertEqual(c.minute, 30)
    }

    func testParseMonthFirst() {
        let date = try! XCTUnwrap(DateFieldParser.parse(cell: cell("03/15/2024"), format: .monthFirstSlash))
        let c = comps(date)
        XCTAssertEqual(c.month, 3); XCTAssertEqual(c.day, 15)
    }

    func testParseSeparatorTolerance() {
        // Column detected as dot still parses the odd dash/slash row.
        XCTAssertNotNil(DateFieldParser.parse(cell: cell("15-03-2024"), format: .dayFirstDot))
        XCTAssertNotNil(DateFieldParser.parse(cell: cell("15/03/2024"), format: .dayFirstDot))
    }

    func testParseSerialCellUsesResolvedDate() {
        let resolved = Calendar.current.date(from: DateComponents(year: 2024, month: 12, day: 31))!
        let date = try! XCTUnwrap(DateFieldParser.parse(cell: cell("45657", serial: resolved), format: .excelSerial))
        let c = comps(date)
        XCTAssertEqual(c.year, 2024); XCTAssertEqual(c.month, 12); XCTAssertEqual(c.day, 31)
        XCTAssertEqual(c.hour, 12)   // midnight serial → noon
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(DateFieldParser.parse(cell: cell("not a date"), format: .dayFirstDot))
        XCTAssertNil(DateFieldParser.parse(cell: cell(""), format: .iso))
    }
}
