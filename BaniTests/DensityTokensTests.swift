import XCTest
import SwiftUI
@testable import Bani

/// D3 — the density token system (B1) resolves three genuinely distinct,
/// monotonically ordered layouts, while the hero/tap-target invariants hold.
final class DensityTokensTests: XCTestCase {

    private let airy = DesignScale.airy.metrics
    private let balanced = DesignScale.balanced.metrics
    private let dense = DesignScale.dense.metrics

    /// Every scaling dimension is strictly ordered airy > balanced > dense —
    /// so the setting reads as a real dial, not three near-identical presets.
    func testMetricsAreStrictlyOrdered() {
        let dims: [(String, KeyPath<DesignMetrics, CGFloat>)] = [
            ("screenPadding", \.screenPadding),
            ("sectionSpacing", \.sectionSpacing),
            ("cardPadding", \.cardPadding),
            ("rowVInset", \.rowVInset),
            ("rowSpacing", \.rowSpacing),
            ("elementSpacing", \.elementSpacing),
            ("chartCardHeight", \.chartCardHeight),
            ("secondaryTextScale", \.secondaryTextScale),
        ]
        for (name, kp) in dims {
            XCTAssertGreaterThan(airy[keyPath: kp], balanced[keyPath: kp], "\(name): airy > balanced")
            XCTAssertGreaterThan(balanced[keyPath: kp], dense[keyPath: kp], "\(name): balanced > dense")
        }
    }

    /// The three levels are pairwise distinct as whole metric bundles.
    func testThreeLevelsAreDistinct() {
        XCTAssertNotEqual(airy, balanced)
        XCTAssertNotEqual(balanced, dense)
        XCTAssertNotEqual(airy, dense)
    }

    /// Hero amounts and the minimum tap target never shrink with density (B1).
    func testInvariantsNeverShrink() {
        XCTAssertEqual(DesignMetrics.minTapTarget, 44)
        // The hero amount font is size-fixed (density-independent) — it is a
        // single shared constant, not derived from any DesignScale.
        XCTAssertEqual(Typography.heroAmount, Font.system(size: 44, weight: .bold).monospacedDigit())
    }

    /// The default density is Balanced, and every raw value round-trips.
    func testRawValueRoundTripAndDefault() {
        XCTAssertEqual(DesignScale(rawValue: "balanced"), .balanced)
        for scale in DesignScale.allCases {
            XCTAssertEqual(DesignScale(rawValue: scale.rawValue), scale)
            XCTAssertFalse(scale.label.isEmpty, "\(scale) must have a localized label")
        }
        XCTAssertNil(DesignScale(rawValue: "gigantic"))
    }
}
