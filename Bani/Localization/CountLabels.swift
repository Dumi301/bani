import Foundation

/// Localized, correctly-pluralized count phrases (B). Interpolating the count
/// into a `String(localized:)` makes each a String-Catalog plural key
/// (`"%lld results"`, …) with per-language plural variations — Romanian carries
/// the one / few / other forms it needs, which a naive `+ "s"` cannot express.
enum CountLabels {
    static func results(_ n: Int) -> String { String(localized: "\(n) results") }
    static func items(_ n: Int) -> String { String(localized: "\(n) items") }
    static func decisions(_ n: Int) -> String { String(localized: "\(n) decisions") }
    static func transactions(_ n: Int) -> String { String(localized: "\(n) transactions") }
}
