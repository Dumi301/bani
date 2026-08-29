import Foundation
import Observation
import SwiftUI

/// Fetches and caches the BNR (Banca Națională a României) daily reference
/// EUR→RON exchange rate from `https://www.bnr.ro/nbrfxrates.xml` (no API
/// key; EUR only). `rate` is DISPLAY-ONLY — a `Double` used purely for
/// showing conversions and totals. Transaction amounts always stay `Decimal`
/// and are NEVER mutated by this service: all conversion happens at display
/// time via `ronEquivalent(of:currency:)`.
///
/// Persistence uses `@AppStorage` PRIMITIVES ONLY (`@AppStorage` cannot store
/// structs or `Decimal`): `"bnr.rate"` (Double), `"bnr.date"` (String — the
/// BNR *publishing* date from the XML, NOT `fetchedAt`), `"bnr.fetchedAt"`
/// (Double, `timeIntervalSince1970`), `"bnr.rateExact"` (String — L5: the
/// literal decimal text backing `rateDecimal`, the exact `Decimal` mirror of
/// `rate` every display multiply should use).
///
/// Weekend/holiday: BNR simply serves the last published rates — there is no
/// special-casing beyond parsing whatever the feed returns.
@MainActor
@Observable
final class RateService {

    /// Minimum interval between network refreshes — named constant, no magic numbers.
    private static let refreshInterval: TimeInterval = 4 * 60 * 60 // 4 hours

    private static let feedURL = URL(string: "https://www.bnr.ro/nbrfxrates.xml")!

    // MARK: Persisted primitives (backing storage)
    //
    // `@AppStorage` and `@Observable`'s stored-property transform cannot both
    // manage the same property, so these are `@ObservationIgnored`. The
    // Observation-tracked, display-facing mirrors below (`rate`,
    // `bnrPublishingDate`, `fetchedAt`) are what views actually read.
    // `Double`/`String` sentinels (`0` / `""`) stand in for "never fetched"
    // since `@AppStorage` has no `Optional<Double>` primitive.

    @ObservationIgnored
    @AppStorage("bnr.rate") private var storedRate: Double = 0

    @ObservationIgnored
    @AppStorage("bnr.date") private var storedDate: String = ""

    @ObservationIgnored
    @AppStorage("bnr.fetchedAt") private var storedFetchedAt: Double = 0

    /// L5: the bit-exact `Decimal` mirror of `storedRate`, persisted SEPARATELY
    /// as its literal decimal text (`Decimal`'s `description` — always "."
    /// decimal point, no grouping — round-trips through `Decimal(string:)`
    /// exactly). NOT derived from `storedRate`/`rate` via `Decimal(Double)`:
    /// that conversion carries the source `Double`'s binary rounding error
    /// (a BNR rate like "4.9761" is not exactly representable in binary
    /// floating point), which is exactly the noise `rateDecimal` exists to
    /// avoid in every display total downstream. Empty sentinel = "never
    /// fetched", mirroring `storedDate`.
    @ObservationIgnored
    @AppStorage("bnr.rateExact") private var storedRateExact: String = ""

    // MARK: Observable, display-facing state
    //
    // Kept as plain (internal) `var`s rather than `private(set)` so
    // `RateServiceTests` can seed a cached rate directly without a
    // network round trip. Production code only ever mutates these from
    // `init()` and `refreshIfNeeded()`.

    /// EUR→RON, display-only. `nil` until a rate has ever been fetched.
    var rate: Double?

    /// L5: EUR→RON as an exact `Decimal` — the source every `Decimal` multiply
    /// against a transaction amount should use (`RateService.ronEquivalent`,
    /// `FinancesAnalytics.ronValue`/`combinedTotal`/`byCategory`/`buckets`/
    /// `cumulative`, `ReceivablesRollup.ronValue`/`build`, `RaportHubBuilder.build`)
    /// instead of converting the `Double` `rate` at the call site. `nil` exactly
    /// when `rate` is `nil`.
    var rateDecimal: Decimal?

    /// The `<Cube date="…">` BNR *publishing* date from the XML — NOT `fetchedAt`.
    var bnrPublishingDate: String?

    /// When this device last successfully fetched a rate.
    var fetchedAt: Date?

    init() {
        rate = storedRate > 0 ? storedRate : nil
        rateDecimal = storedRateExact.isEmpty ? nil : Decimal(string: storedRateExact)
        bnrPublishingDate = storedDate.isEmpty ? nil : storedDate
        fetchedAt = storedFetchedAt > 0 ? Date(timeIntervalSince1970: storedFetchedAt) : nil
    }

    /// Refreshes the cached rate from BNR, but at most once per
    /// `refreshInterval`. Intended to be called on app foreground (wired by
    /// the app root — see interfaces.md). Any failure — network, decoding,
    /// or parsing — is SILENT: the cached values are left exactly as they
    /// were.
    func refreshIfNeeded() async {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.refreshInterval {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: Self.feedURL)
            guard let xml = String(data: data, encoding: .utf8),
                  let parsed = Self.parseEURRate(fromBNRXML: xml) else {
                return // silent failure — keep whatever is cached
            }

            let now = Date()
            rate = parsed.rate
            rateDecimal = parsed.rateDecimal
            bnrPublishingDate = parsed.date
            fetchedAt = now

            storedRate = parsed.rate
            storedRateExact = "\(parsed.rateDecimal)"
            storedDate = parsed.date
            storedFetchedAt = now.timeIntervalSince1970
        } catch {
            // Silent failure — cached rate (if any) keeps working.
        }
    }

    /// Display-time conversion only — never mutates stored transactions.
    /// `.ron` passes the amount through unchanged. `.eur` converts using the
    /// cached rate, or returns `nil` if no rate has ever been fetched (the
    /// caller then falls back to per-currency totals, never a guessed rate).
    /// L5: multiplies by `rateDecimal` (falling back to `Decimal(rate)` only
    /// when `rateDecimal` wasn't populated — e.g. a caller that seeded `rate`
    /// directly without going through `refreshIfNeeded()`/`init()`) rather than
    /// converting the `Double` `rate` here, so the everyday path never
    /// reintroduces the binary-float rounding noise `rateDecimal` exists to avoid.
    func ronEquivalent(of amount: Decimal, currency: Currency) -> Decimal? {
        switch currency {
        case .ron:
            return amount
        case .eur:
            guard let exact = rateDecimal ?? rate.map({ Decimal($0) }) else { return nil }
            return amount * exact
        }
    }

    /// Testing seam: parse a raw XML string. Pure, no network. Parses the
    /// BNR `nbrfxrates.xml` shape (default namespace
    /// `http://www.bnr.ro/xsd`, so `XMLParser` reports unprefixed element
    /// names — `"Cube"`, `"Rate"` — with no extra namespace configuration
    /// needed) and extracts the `<Cube date="…">` publishing date plus the
    /// `<Rate currency="EUR">` value. Numbers are dot-decimal, parsed with a
    /// FIXED `en_US_POSIX` locale regardless of device locale. Returns `nil`
    /// on any parse failure or a missing EUR rate. L5: `rateDecimal` is parsed
    /// directly from the XML's raw decimal text via `Decimal(string:)` — never
    /// derived from `rate` (the `Double`) — so it carries none of the binary
    /// floating-point rounding a `Decimal(Double)` conversion would.
    nonisolated static func parseEURRate(fromBNRXML xml: String) -> (rate: Double, rateDecimal: Decimal, date: String)? {
        guard let data = xml.data(using: .utf8) else { return nil }

        let delegate = BNRRateXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse(),
              let date = delegate.cubeDate,
              let rate = delegate.eurRate,
              let rateDecimal = delegate.eurRateExact else {
            return nil
        }
        return (rate, rateDecimal, date)
    }
}

/// `XMLParserDelegate` used only by `RateService.parseEURRate`. Kept private
/// to this file — it is an implementation detail of the parsing seam, not
/// part of the frozen public surface.
private final class BNRRateXMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var cubeDate: String?
    private(set) var eurRate: Double?
    /// L5: parsed straight from the trimmed XML text via `Decimal(string:)` —
    /// a separate, zero-Double-intermediate path from `eurRate` (see
    /// `RateService.parseEURRate`'s doc).
    private(set) var eurRateExact: Decimal?

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private var isCapturingEURRate = false
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Cube":
            if let date = attributeDict["date"] {
                cubeDate = date
            }
        case "Rate":
            if attributeDict["currency"] == "EUR" {
                isCapturingEURRate = true
                currentText = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isCapturingEURRate else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "Rate", isCapturingEURRate else { return }
        isCapturingEURRate = false

        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.locale = Self.posixLocale
        formatter.numberStyle = .decimal
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ""

        if let number = formatter.number(from: trimmed) {
            eurRate = number.doubleValue
        }
        // L5: exact decimal digits, no `Double` in the path at all (unlike
        // `eurRate` above via `NumberFormatter.doubleValue`). `Decimal(string:)`
        // with a nil locale always expects "." as the decimal point (matching
        // the fixed-POSIX text BNR publishes), so no locale argument is needed.
        eurRateExact = Decimal(string: trimmed)
    }
}
