import XCTest
import SwiftData
@testable import Bani

/// v2 "Balance anchoring / reconciliation" — the end-to-end acceptance proof on a
/// real in-memory container: seed logged flows → reconcile → adjust + anchor →
/// the portfolio's net logged position (what `LiquidityCalculator` consumes) equals
/// the anchored reality. Plus: the adjustment carries NO projectID (never pollutes a
/// project P&L), a clean second reconcile creates nothing, [Just anchor] resets the
/// baseline without writing a transaction, and a live `LoanStore` booking flows
/// through reconciliation exactly as booked (composes with P3).
@MainActor
final class ReconciliationFlowTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, ScheduledItem.self, Project.self, Loan.self,
            CustomCategory.self, BalanceAnchor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    /// The production net-logged-position path (income − expense, neutral excluded),
    /// the number the portfolio header shows and `LiquidityCalculator` consumes.
    private func netLoggedPosition(in ctx: ModelContext) throws -> Decimal {
        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        let lines = txs.map {
            ProjectTxLine(amount: $0.amount, currency: $0.currency, direction: $0.direction,
                          projectID: $0.projectID, date: $0.date)
        }
        return ProjectAnalytics.netLoggedPosition(lines, rate: nil)
    }

    @discardableResult
    private func seed(_ ctx: ModelContext, _ direction: TransactionDirection, _ amount: Decimal,
                      projectID: UUID? = nil, offsetDays: Double = -5) -> Transaction {
        let tx = Transaction(
            amount: amount, currency: .ron, context: .work,
            descriptionText: "seed", date: fixedNow.addingTimeInterval(offsetDays * 86_400),
            source: .manual, direction: direction, projectID: projectID
        )
        ctx.insert(tx)
        return tx
    }

    // MARK: - Acceptance: adjust + anchor ⇒ position == reality

    func testAdjustThenAnchorMakesPositionEqualRealityAndSecondReconcileIsClean() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let projectID = UUID()

        // Seed logged flows: +1000 income (into a project), −300 expense. The
        // project assignment proves the adjustment stays project-free even though
        // logged flows may be project-scoped. netLoggedPosition = 700.
        seed(ctx, .income, 1000, projectID: projectID)
        seed(ctx, .expense, 300)
        try ctx.save()
        XCTAssertEqual(try netLoggedPosition(in: ctx), 700)

        // Reconcile against a real balance of 650 → drift −50 (a missed expense).
        let result1 = ReconciliationStore.result(actual: 650, currency: .ron, in: ctx)
        XCTAssertEqual(result1.expected, 700)
        XCTAssertEqual(result1.drift, -50)
        XCTAssertEqual(result1.adjustmentDirection, .expense)

        let commit = ReconciliationStore.createAdjustmentAndAnchor(result: result1, now: fixedNow, in: ctx)

        // The adjustment: a real, auditable expense of 50, NO project, NO loan, no
        // transcript, tagged with the reconciliation category.
        let adj = try XCTUnwrap(commit.adjustment)
        XCTAssertEqual(adj.direction, .expense)
        XCTAssertEqual(adj.amount, 50)
        XCTAssertNil(adj.projectID, "the adjustment must NEVER carry a projectID")
        XCTAssertNil(adj.loanID)
        XCTAssertNil(adj.rawTranscript)
        XCTAssertEqual(adj.customCategoryID, ReconciliationCategories.adjustmentCategoryID)

        // ACCEPTANCE: net logged position now equals the anchored reality.
        let position = try netLoggedPosition(in: ctx)
        XCTAssertEqual(position, 650, "after adjust + anchor, the position equals reality")
        let liq = LiquidityCalculator.result(netLoggedPosition: position, pendingItems: [],
                                             horizon: .days30, rate: nil, now: fixedNow)
        XCTAssertEqual(liq.freeLiquidity, 650, "LiquidityCalculator's current position == anchored reality")

        // The anchor recorded the reality point + the drift it closed.
        let anchors = try ctx.fetch(FetchDescriptor<BalanceAnchor>())
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors.first?.amount, 650)
        XCTAssertEqual(anchors.first?.driftAtAnchor, -50)

        // SECOND reconcile at the same reality, no new flows ⇒ zero drift ⇒ nothing.
        let result2 = ReconciliationStore.result(actual: 650, currency: .ron, in: ctx)
        XCTAssertEqual(result2.expected, 650, "baseline is the anchor; the adjustment at the anchor instant is not re-counted")
        XCTAssertEqual(result2.drift, 0)
        XCTAssertTrue(result2.isBalanced)

        let txCountBefore = try ctx.fetchCount(FetchDescriptor<Transaction>())
        let commit2 = ReconciliationStore.createAdjustmentAndAnchor(result: result2, now: fixedNow.addingTimeInterval(60), in: ctx)
        XCTAssertNil(commit2.adjustment, "a zero-drift reconcile creates NO adjustment transaction")
        let txCountAfter = try ctx.fetchCount(FetchDescriptor<Transaction>())
        XCTAssertEqual(txCountAfter, txCountBefore, "no transaction is written on a clean reconcile")
    }

    // MARK: - Just anchor resets the baseline without a transaction

    func testJustAnchorRecordsRealityWithoutTransactionAndResetsBaseline() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        seed(ctx, .income, 1000)
        try ctx.save()
        XCTAssertEqual(try netLoggedPosition(in: ctx), 1000)

        // Real balance is 800 (−200 drift) but the client just anchors — accepting
        // the number going forward, writing no adjustment.
        let result = ReconciliationStore.result(actual: 800, currency: .ron, in: ctx)
        XCTAssertEqual(result.drift, -200)

        let txCountBefore = try ctx.fetchCount(FetchDescriptor<Transaction>())
        let anchor = ReconciliationStore.anchorOnly(result: result, now: fixedNow, in: ctx)
        XCTAssertEqual(anchor.amount, 800)
        XCTAssertEqual(anchor.driftAtAnchor, -200)
        // L3: the unclosed drift is recorded as the anchor's open residual —
        // visibility only, the math above (drift/baseline) is untouched.
        XCTAssertEqual(anchor.unresolvedResidual, -200, "anchorOnly with non-zero drift records the unclosed gap as a residual")

        // No transaction written; the position is unchanged by a bare anchor.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>()), txCountBefore, "Just anchor writes no transaction")
        XCTAssertEqual(try netLoggedPosition(in: ctx), 1000, "a bare anchor never moves the position")

        // But the drift baseline is reset: reconciling at 800 again is now clean.
        let result2 = ReconciliationStore.result(actual: 800, currency: .ron, in: ctx)
        XCTAssertEqual(result2.expected, 800, "baseline reset to the anchored reality")
        XCTAssertEqual(result2.drift, 0)

        // L3: anchoring again at zero drift leaves NO open residual (nothing unclosed).
        let anchorClean = ReconciliationStore.anchorOnly(result: result2, now: fixedNow.addingTimeInterval(60), in: ctx)
        XCTAssertNil(anchorClean.unresolvedResidual, "a zero-drift anchorOnly records no residual")
    }

    // MARK: - L3: anchorOnly residual visibility

    /// `createAdjustmentAndAnchor` CLOSES the drift with a real transaction, so its
    /// anchor must never carry an open residual — only the `anchorOnly` (no
    /// adjustment) path can leave one. Math (drift/position) is identical to
    /// `testAdjustThenAnchorMakesPositionEqualRealityAndSecondReconcileIsClean`.
    func testCreateAdjustmentAndAnchorNeverRecordsResidual() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        seed(ctx, .income, 1000)
        seed(ctx, .expense, 300)
        try ctx.save()

        let result = ReconciliationStore.result(actual: 650, currency: .ron, in: ctx)
        XCTAssertEqual(result.drift, -50)

        let commit = ReconciliationStore.createAdjustmentAndAnchor(result: result, now: fixedNow, in: ctx)
        XCTAssertNotNil(commit.adjustment, "sanity: the drift WAS closed by a real adjustment")
        XCTAssertNil(commit.anchor.unresolvedResidual, "a drift closed by an adjustment leaves no open residual")
    }

    // MARK: - Composition with P3: a live loan booking flows through as booked

    func testBookedLoanPaymentMovesReconciliationByInterestOnly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let t0 = fixedNow.addingTimeInterval(-86_400)          // anchor instant
        let start = cal.date(from: DateComponents(year: 2025, month: 12, day: 20, hour: 9))!

        // An interest-bearing bank loan so the interest slice is non-zero.
        let loan = Loan(name: "Credit", lender: "BCR", kind: .bank, principal: 12_000,
                        currency: .ron, annualRatePercent: 12, startDate: start,
                        termMonths: 12, projectID: UUID())
        _ = LoanStore.createLoan(loan, calendar: cal, in: ctx)

        // Anchor real cash at 50 000 before any payment is booked.
        ctx.insert(BalanceAnchor(amount: 50_000, currency: .ron, anchoredAt: t0))
        try ctx.save()

        // Book the first scheduled payment AFTER the anchor: writes an interest
        // (expense) slice + a principal (neutral) slice.
        let firstItem = try XCTUnwrap(
            try ctx.fetch(FetchDescriptor<ScheduledItem>())
                .filter { $0.status == .pending }
                .sorted { $0.dueDate < $1.dueDate }
                .first
        )
        let booked = try XCTUnwrap(LoanStore.bookPayment(firstItem, loan: loan, date: fixedNow, calendar: cal, in: ctx))
        let interest = booked.interest.amount
        XCTAssertGreaterThan(interest, 0, "an interest-bearing loan books a non-zero interest slice")

        // Reconciliation and netLoggedPosition both move by ONLY the interest — the
        // neutral principal slice never registers (P3's no-double-count basis).
        XCTAssertEqual(try netLoggedPosition(in: ctx), -interest, "position dropped by interest only; principal (neutral) excluded")

        let result = ReconciliationStore.result(actual: 50_000 - interest, currency: .ron, in: ctx)
        XCTAssertEqual(result.expected, 50_000 - interest, "booked loan payment moves expected by interest only")
        XCTAssertEqual(result.drift, 0, "a correctly-booked loan payment produces NO false drift")
    }
}
