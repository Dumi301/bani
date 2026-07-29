import XCTest
@testable import Bani

/// Tests for `RateService`. No live network calls are made — only the
/// bundled `bnr-fixture.xml` and synthetic in-memory XML strings are fed to
/// the pure `parseEURRate` seam, matching "Live mic/network is never used in
/// CI" for this unit's tests too.
@MainActor
final class RateServiceTests: XCTestCase {

    private static let bnrRateKey = "bnr.rate"
    private static let bnrDateKey = "bnr.date"
    private static let bnrFetchedAtKey = "bnr.fetchedAt"

    override func setUp() {
        super.setUp()
        clearPersistedRate()
    }

    override func tearDown() {
        clearPersistedRate()
        super.tearDown()
    }

    /// `@AppStorage` in `RateService` reads/writes `UserDefaults.standard`
    /// under the test host app's domain, which can persist across CI runs on
    /// the same simulator. Clear it so "no cached rate" tests are
    /// deterministic regardless of prior state.
    // `nonisolated` so the nonisolated setUp()/tearDown() overrides can call it
    // (it only touches the Sendable UserDefaults.standard).
    nonisolated private func clearPersistedRate() {
        UserDefaults.standard.removeObject(forKey: Self.bnrRateKey)
        UserDefaults.standard.removeObject(forKey: Self.bnrDateKey)
        UserDefaults.standard.removeObject(forKey: Self.bnrFetchedAtKey)
    }

    // MARK: - Fixture loading

    /// Loads `bnr-fixture.xml` from the test bundle. XcodeGen's
    /// `syncedFolder` resource handling can land a nested-folder resource at
    /// a couple of plausible bundle paths depending on how the synchronized
    /// group flattens `BaniTests/Fixtures/` — try the likely spots before
    /// concluding it's genuinely missing.
    private func loadFixtureXML() throws -> String {
        let bundle = Bundle(for: Self.self)
        let candidate = bundle.url(forResource: "bnr-fixture", withExtension: "xml", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "bnr-fixture", withExtension: "xml")
            ?? bundle.urls(forResourcesWithExtension: "xml", subdirectory: nil)?
                .first(where: { $0.lastPathComponent == "bnr-fixture.xml" })

        guard let url = candidate else {
            throw XCTSkip("bnr-fixture.xml not found in the test bundle — resource genuinely missing")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - parseEURRate

    func testParseEURRateFromBundledFixture() throws {
        let xml = try loadFixtureXML()
        let parsed = try XCTUnwrap(RateService.parseEURRate(fromBNRXML: xml))

        XCTAssertEqual(parsed.rate, 4.9761, accuracy: 0.0001)
        XCTAssertEqual(parsed.date, "2024-05-31")
    }

    /// BNR serves whatever it last published — `parseEURRate` has no
    /// weekend/holiday special-casing anywhere. 2024-05-31 is a Friday;
    /// parsing must succeed identically no matter what "today" is when this
    /// test runs, since nothing branches on the current date.
    func testParsesLastPublishedRateWithNoWeekendOrHolidaySpecialCasing() throws {
        let xml = try loadFixtureXML()
        let parsed = try XCTUnwrap(RateService.parseEURRate(fromBNRXML: xml))

        XCTAssertEqual(parsed.date, "2024-05-31")
        XCTAssertEqual(parsed.rate, 4.9761, accuracy: 0.0001)
    }

    func testParseEURRateUsesFixedPOSIXLocaleNotDeviceLocale() throws {
        let xml = try loadFixtureXML()
        let parsed = try XCTUnwrap(RateService.parseEURRate(fromBNRXML: xml))

        // If "." were misread as a grouping (thousands) separator — which is
        // what a comma-decimal locale such as ro_RO/de_DE would do — the
        // parsed value would not come out as 4.9761. Confirms the dot was
        // read as a decimal point, not stripped as a grouping separator.
        XCTAssertEqual(parsed.rate, 4.9761, accuracy: 0.0001)
        XCTAssertNotEqual(parsed.rate, 49761, accuracy: 0.0001)

        // Directly cross-check against an explicit en_US_POSIX formatter
        // parsing the same raw token, independent of whatever locale this
        // test happens to run under.
        let posixFormatter = NumberFormatter()
        posixFormatter.locale = Locale(identifier: "en_US_POSIX")
        posixFormatter.numberStyle = .decimal
        let posixParsed = try XCTUnwrap(posixFormatter.number(from: "4.9761")?.doubleValue)
        XCTAssertEqual(parsed.rate, posixParsed, accuracy: 0.0001)
    }

    func testParseEURRateReturnsNilForMalformedXML() {
        XCTAssertNil(RateService.parseEURRate(fromBNRXML: "<not><valid"))
        XCTAssertNil(RateService.parseEURRate(fromBNRXML: ""))
    }

    func testParseEURRateReturnsNilWhenEURRateMissing() {
        let xmlWithoutEUR = """
        <DataSet xmlns="http://www.bnr.ro/xsd">
          <Body>
            <Cube date="2024-05-31">
              <Rate currency="USD">4.5928</Rate>
            </Cube>
          </Body>
        </DataSet>
        """
        XCTAssertNil(RateService.parseEURRate(fromBNRXML: xmlWithoutEUR))
    }

    // MARK: - ronEquivalent

    func testRonEquivalentConvertsEURUsingCachedRate() {
        let service = RateService()
        service.rate = 4.9761

        let result = service.ronEquivalent(of: Decimal(10), currency: .eur)
        XCTAssertEqual(result, Decimal(10) * Decimal(4.9761))
    }

    func testRonEquivalentPassesRONThroughUnchanged() {
        let service = RateService()
        let amount = Decimal(string: "123.45")!

        let result = service.ronEquivalent(of: amount, currency: .ron)
        XCTAssertEqual(result, amount)
    }

    func testRonEquivalentReturnsNilForEURWhenNoRateCached() {
        let service = RateService()
        XCTAssertNil(service.rate) // sanity: nothing persisted, nothing seeded

        let result = service.ronEquivalent(of: Decimal(10), currency: .eur)
        XCTAssertNil(result)
    }
}
