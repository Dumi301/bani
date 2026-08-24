import XCTest
@testable import Bani

/// v2 "Balance anchoring / reconciliation" — the drift math is a pure computation
/// with its own tests: expected-balance across every direction (incl. loan
/// interest/principal slices counted exactly as booked), drift sign both ways, the
/// baseline window, and the same-currency multi-currency rule. Proven independent
/// of any UI or `ModelContext`.
final class ReconciliationEngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func flow(
        _ direction: TransactionDirection,
        _ amount: Decimal,
        _ currency: Currency = .ron,
        offsetDays: Double = -5
    ) -> ReconciliationFlow {
        ReconciliationFlow(amount: amount, currency: currency, direction: direction,
                           date: now.addingTimeInterval(offsetDays * 86_400))
    }

    // MARK: - Expected balance across directions

    /// No anchor ⇒ baseline 0, every flow counted: income adds, expense subtracts,
    /// neutral contributes nothing (the netLoggedPosition basis).
    func testExpectedWithNoAnchorSumsAllDirectionsNeutralExcluded() {
        let flows = [
            flow(.income, 1000),
            flow(.expense, 300),
            flow(.neutral, 5000),   // transfer / cash move — must NOT move the balance
        ]
        let r = ReconciliationEngine.reconcile(actual: 700, currency: .ron, anchor: nil, flows: flows)
        XCTAssertEqual(r.baseline, 0)
        XCTAssertEqual(r.netLoggedSinceAnchor, 700, "1000 − 300, neutral excluded")
        XCTAssertEqual(r.expected, 700)
        XCTAssertEqual(r.drift, 0)
        XCTAssertTrue(r.isBalanced)
        XCTAssertEqual(r.countedFlows, 2, "only income + expense move the number")
        XCTAssertNil(r.adjustmentDirection)
    }

    /// A booked loan payment is an interest slice (`.expense`) + a principal slice
    /// (`.neutral`). "Counted exactly as booked": the payment lowers the expected
    /// balance by ONLY its interest — the same amount it lowered netLoggedPosition
    /// by — and the neutral principal never registers as drift (composes with P3's
    /// no-double-count booking / `loanAdjustment == 0`).
    func testLoanSlicesCountedExactlyAsBooked() {
        let flows = [
            flow(.expense, 100, offsetDays: -2),   // interest slice
            flow(.neutral, 900, offsetDays: -2),   // principal slice
        ]
        let r = ReconciliationEngine.reconcile(actual: 9900, currency: .ron,
                                               anchor: ReconciliationAnchor(amount: 10_000, currency: .ron, anchoredAt: now.addingTimeInterval(-10 * 86_400)),
                                               flows: flows)
        XCTAssertEqual(r.netLoggedSinceAnchor, -100, "only the interest slice moves the balance")
        XCTAssertEqual(r.expected, 9900, "10 000 − 100 interest; principal (neutral) excluded")
        XCTAssertEqual(r.drift, 0, "paying a loan correctly produces NO false drift")
        XCTAssertEqual(r.countedFlows, 1)
    }

    // MARK: - Anchor baseline + window

    /// Expected = anchor amount + net flows strictly AFTER the anchor instant. Flows
    /// dated on/before the anchor are part of the baseline and never re-counted.
    func testAnchorBaselineWindowsFlowsStrictlyAfter() {
        let anchoredAt = now.addingTimeInterval(-7 * 86_400)
        let flows = [
            flow(.income, 500, offsetDays: -10),   // before anchor → excluded
            flow(.expense, 200, offsetDays: -3),   // after anchor  → counted
            flow(.income, 100, offsetDays: -1),    // after anchor  → counted
        ]
        let anchor = ReconciliationAnchor(amount: 2000, currency: .ron, anchoredAt: anchoredAt)
        let r = ReconciliationEngine.reconcile(actual: 1900, currency: .ron, anchor: anchor, flows: flows)
        XCTAssertTrue(r.hasAnchor)
        XCTAssertEqual(r.baseline, 2000)
        XCTAssertEqual(r.netLoggedSinceAnchor, -100, "−200 + 100; the pre-anchor +500 is excluded")
        XCTAssertEqual(r.expected, 1900)
        XCTAssertEqual(r.drift, 0)
    }

    /// A flow dated exactly AT the anchor instant is part of the baseline (strict
    /// `>`), so a closing adjustment stamped on the anchor moment is never
    /// re-counted by the next reconcile.
    func testFlowAtAnchorInstantIsExcluded() {
        let anchoredAt = now
        let flows = [ ReconciliationFlow(amount: 50, currency: .ron, direction: .expense, date: anchoredAt) ]
        let anchor = ReconciliationAnchor(amount: 650, currency: .ron, anchoredAt: anchoredAt)
        let r = ReconciliationEngine.reconcile(actual: 650, currency: .ron, anchor: anchor, flows: flows)
        XCTAssertEqual(r.netLoggedSinceAnchor, 0, "the flow at the anchor instant is baseline, not a later flow")
        XCTAssertEqual(r.expected, 650)
        XCTAssertEqual(r.drift, 0)
    }

    // MARK: - Drift sign both ways

    /// actual < expected ⇒ negative drift ⇒ a closing EXPENSE (money went missing).
    func testNegativeDriftClosesWithExpense() {
        let flows = [flow(.income, 1000), flow(.expense, 300)]   // expected 700
        let r = ReconciliationEngine.reconcile(actual: 650, currency: .ron, anchor: nil, flows: flows)
        XCTAssertEqual(r.drift, -50)
        XCTAssertEqual(r.adjustmentDirection, .expense)
        XCTAssertEqual(r.adjustmentAmount, 50)
        XCTAssertFalse(r.isBalanced)
    }

    /// actual > expected ⇒ positive drift ⇒ a closing INCOME (unlogged money in).
    func testPositiveDriftClosesWithIncome() {
        let flows = [flow(.income, 1000), flow(.expense, 300)]   // expected 700
        let r = ReconciliationEngine.reconcile(actual: 900, currency: .ron, anchor: nil, flows: flows)
        XCTAssertEqual(r.drift, 200)
        XCTAssertEqual(r.adjustmentDirection, .income)
        XCTAssertEqual(r.adjustmentAmount, 200)
    }

    /// Zero drift ⇒ nothing to adjust.
    func testZeroDriftHasNoAdjustment() {
        let r = ReconciliationEngine.reconcile(actual: 700, currency: .ron, anchor: nil,
                                               flows: [flow(.income, 1000), flow(.expense, 300)])
        XCTAssertTrue(r.isBalanced)
        XCTAssertNil(r.adjustmentDirection)
        XCTAssertEqual(r.adjustmentAmount, 0)
    }

    // MARK: - Multi-currency rule (same-currency only, never converted)

    /// The expected balance is computed in the anchor's currency by counting ONLY
    /// same-currency flows at face value. Flows in another currency are excluded
    /// (never converted) and surfaced via `excludedCurrencyFlows`.
    func testForeignCurrencyFlowsExcludedNotConverted() {
        let anchor = ReconciliationAnchor(amount: 1000, currency: .ron, anchoredAt: now.addingTimeInterval(-10 * 86_400))
        let flows = [
            flow(.expense, 200, .ron, offsetDays: -2),   // counted
            flow(.income, 50, .eur, offsetDays: -2),     // EXCLUDED — different currency
            flow(.expense, 30, .eur, offsetDays: -1),    // EXCLUDED — different currency
        ]
        let r = ReconciliationEngine.reconcile(actual: 800, currency: .ron, anchor: anchor, flows: flows)
        XCTAssertEqual(r.netLoggedSinceAnchor, -200, "only the RON expense counts; EUR never converted")
        XCTAssertEqual(r.expected, 800)
        XCTAssertEqual(r.drift, 0, "the RON account reconciles exactly, EUR flows set aside")
        XCTAssertEqual(r.countedFlows, 1)
        XCTAssertEqual(r.excludedCurrencyFlows, 2)
    }

    /// A EUR anchor reconciles the EUR account: EUR flows count, RON flows are set
    /// aside. Symmetric to the RON case — each currency is exact against its own
    /// account.
    func testEURAnchorCountsEURFlowsOnly() {
        let anchor = ReconciliationAnchor(amount: 500, currency: .eur, anchoredAt: now.addingTimeInterval(-10 * 86_400))
        let flows = [
            flow(.income, 100, .eur, offsetDays: -2),    // counted
            flow(.expense, 9999, .ron, offsetDays: -1),  // EXCLUDED
        ]
        let r = ReconciliationEngine.reconcile(actual: 600, currency: .eur, anchor: anchor, flows: flows)
        XCTAssertEqual(r.expected, 600, "500 + 100 EUR; the RON flow is set aside")
        XCTAssertEqual(r.drift, 0)
        XCTAssertEqual(r.excludedCurrencyFlows, 1)
    }

    /// An anchor whose currency differs from the reconcile currency is ignored as if
    /// absent (the caller resolves the latest anchor OF the target currency; this
    /// guards a mismatch defensively).
    func testMismatchedAnchorCurrencyIsIgnored() {
        let eurAnchor = ReconciliationAnchor(amount: 500, currency: .eur, anchoredAt: now.addingTimeInterval(-10 * 86_400))
        let r = ReconciliationEngine.reconcile(actual: 700, currency: .ron, anchor: eurAnchor,
                                               flows: [flow(.income, 1000), flow(.expense, 300)])
        XCTAssertFalse(r.hasAnchor, "a EUR anchor is not a baseline for a RON reconcile")
        XCTAssertEqual(r.baseline, 0)
        XCTAssertEqual(r.expected, 700, "falls back to logged-from-zero")
    }
}
