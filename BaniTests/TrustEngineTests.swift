import XCTest
@testable import Bani

/// B6 — the pure trust math: trailing-accuracy window, promotion at 95%/10,
/// demotion below 90% (with the 90–95% hysteresis band), and the context-rule
/// promotion predicate at 3/80%. No SwiftData — this is the deterministic core.
final class TrustEngineTests: XCTestCase {

    // MARK: - Trailing accuracy window

    func testTrailingAccuracyEmptyIsZero() {
        let (accuracy, count) = TrustEngine.trailingAccuracy([])
        XCTAssertEqual(accuracy, 0)
        XCTAssertEqual(count, 0)
    }

    func testTrailingAccuracyUsesOnlyTheLastTwenty() {
        // 5 misses then 20 hits → the window (last 20) is all hits.
        let samples = Array(repeating: false, count: 5) + Array(repeating: true, count: 20)
        let (accuracy, count) = TrustEngine.trailingAccuracy(samples)
        XCTAssertEqual(count, 20)
        XCTAssertEqual(accuracy, 1.0, accuracy: 0.0001)
    }

    // MARK: - Promotion

    func testNotTrustedBelowMinimumDecisions() {
        // 9 perfect decisions — high accuracy but not enough volume.
        XCTAssertFalse(TrustEngine.isTrusted(Array(repeating: true, count: 9)))
    }

    func testPromotedAtTenPerfectDecisions() {
        XCTAssertTrue(TrustEngine.isTrusted(Array(repeating: true, count: 10)))
    }

    func testNotPromotedAtNinetyPercent() {
        // 10 decisions, one miss → 0.90 accuracy, below the 0.95 promotion bar.
        let samples = Array(repeating: true, count: 9) + [false]
        XCTAssertFalse(TrustEngine.isTrusted(samples))
    }

    func testPromotedAtExactlyNinetyFivePercentOverTwenty() {
        // 20 decisions, one miss → 0.95 accuracy, ≥10 volume → trusted.
        let samples = Array(repeating: true, count: 19) + [false]
        XCTAssertTrue(TrustEngine.isTrusted(samples))
    }

    // MARK: - Demotion (hysteresis)

    func testDemotedWhenTrailingDropsBelowNinety() {
        // Earn trust (20 hits), then enough misses that the last-20 window falls
        // under 0.90 → trust is lost.
        let samples = Array(repeating: true, count: 20) + Array(repeating: false, count: 3)
        XCTAssertFalse(TrustEngine.isTrusted(samples), "17/20 = 0.85 < 0.90 → demoted")
    }

    func testHoldsTrustAtExactlyNinetyPercent() {
        // 18 hits + 2 misses in the window = exactly 0.90 → NOT below 0.90 → held.
        let samples = Array(repeating: true, count: 20) + Array(repeating: false, count: 2)
        XCTAssertTrue(TrustEngine.isTrusted(samples), "18/20 = 0.90 is not below the 0.90 demotion bar")
    }

    func testTrustIsRegainableAfterRecovery() {
        // trusted → demoted → then a clean run of 20 hits re-promotes.
        let samples = Array(repeating: true, count: 20)
            + Array(repeating: false, count: 3)   // demote
            + Array(repeating: true, count: 20)   // recover
        XCTAssertTrue(TrustEngine.isTrusted(samples))
    }

    // MARK: - Context-rule promotion (3 / 80%)

    func testContextPromotesAtThreeConfirmationsAndFullAccuracy() {
        XCTAssertEqual(ContextTrust.preselected([.work: 3]), .work)
    }

    func testContextNotPromotedBelowThreeConfirmations() {
        XCTAssertNil(ContextTrust.preselected([.work: 2]))
    }

    func testContextNotPromotedBelowEightyPercent() {
        // work 3 of 4 total = 0.75 < 0.80.
        XCTAssertNil(ContextTrust.preselected([.work: 3, .personal: 1]))
    }

    func testContextPromotedAtExactlyEightyPercent() {
        // work 4 of 5 total = 0.80.
        XCTAssertEqual(ContextTrust.preselected([.work: 4, .personal: 1]), .work)
    }

    func testContextEmptyVotesIsNil() {
        XCTAssertNil(ContextTrust.preselected([:]))
    }
}
