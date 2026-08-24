import XCTest
@testable import Bani

/// v1.2b "Loans" — the amortization math is a pure computation with its own tests:
/// the interest/principal split vs a hand-computed fixture, the property that
/// rounded slices sum EXACTLY to principal (+ total interest), the interest-free
/// (zero-rate) path, and final-payment residual absorption. No `ModelContext`.
final class AmortizationScheduleTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func startDate() -> Date {
        bucharestCalendar().date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
    }

    // MARK: - Hand-computed split fixture

    /// 10 000 RON at 12% nominal annual (= 1% per month) over 12 months. The first
    /// interest slice is hand-verifiable: 10 000 × 0.01 = 100.00. The level annuity
    /// payment is 10 000·0.01·(1.01)¹² / ((1.01)¹² − 1) = 888.49 (to the cent), so
    /// the first principal slice is 888.49 − 100.00 = 788.49.
    func testFirstSplitMatchesHandComputedFixture() {
        let schedule = AmortizationSchedule.schedule(
            principal: 10_000, annualRatePercent: dec("12"), termMonths: 12,
            startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
        )
        XCTAssertEqual(schedule.count, 12)
        let first = schedule[0]
        XCTAssertEqual(first.interest, dec("100.00"), "first interest = balance × monthlyRate = 10000 × 0.01")
        XCTAssertEqual(first.payment, dec("888.49"), "level annuity payment, to the cent")
        XCTAssertEqual(first.principal, dec("788.49"), "principal = payment − interest")
        XCTAssertEqual(first.payment, first.interest + first.principal, "row identity: payment = interest + principal")
        // The first payment falls one month after the start date.
        let expectedFirstDue = bucharestCalendar().date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 9))!
        XCTAssertEqual(first.dueDate, expectedFirstDue)
    }

    /// The whiteboard-sized fixture: 100 000 RON at 7.9% over 240 months. First
    /// interest = round(100000 × 0.079/12) = round(658.3333…) = 658.33. Balance
    /// strictly decreases to exactly 0 across 240 rows.
    func testLongLoanFirstInterestAndTermination() {
        let schedule = AmortizationSchedule.schedule(
            principal: 100_000, annualRatePercent: dec("7.9"), termMonths: 240,
            startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
        )
        XCTAssertEqual(schedule.count, 240)
        XCTAssertEqual(schedule[0].interest, dec("658.33"), "first interest = round(100000 × 0.079/12)")
        XCTAssertEqual(schedule.last?.balanceAfter, 0, "the final balance is exactly zero")
        // Balance is monotonically non-increasing.
        for i in 1..<schedule.count {
            XCTAssertLessThanOrEqual(schedule[i].balanceAfter, schedule[i - 1].balanceAfter)
        }
    }

    // MARK: - Rounding sums EXACTLY

    /// The property the whole design turns on: because the final payment absorbs the
    /// residual, the rounded principal slices sum to EXACTLY the principal, and the
    /// payments sum to EXACTLY principal + total interest — no penny drift.
    func testRoundedSlicesSumExactly() {
        let schedule = AmortizationSchedule.schedule(
            principal: 100_000, annualRatePercent: dec("7.9"), termMonths: 240,
            startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
        )
        let principalSum = schedule.reduce(Decimal(0)) { $0 + $1.principal }
        XCTAssertEqual(principalSum, 100_000, "Σ principal slices == original principal, exactly")

        let interestSum = AmortizationSchedule.totalInterest(schedule)
        let paymentSum = AmortizationSchedule.totalPaid(schedule)
        XCTAssertEqual(paymentSum, 100_000 + interestSum, "Σ payments == principal + Σ interest, exactly")

        // Every row obeys payment = interest + principal (no independent rounding).
        for row in schedule {
            XCTAssertEqual(row.payment, row.interest + row.principal)
        }
    }

    // MARK: - Zero / nil rate (interest-free)

    func testZeroRateIsAllPrincipal() {
        for rate in [Decimal?.none, Decimal?.some(0)] {
            let schedule = AmortizationSchedule.schedule(
                principal: 1_200, annualRatePercent: rate, termMonths: 12,
                startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
            )
            XCTAssertEqual(schedule.count, 12)
            XCTAssertTrue(schedule.allSatisfy { $0.interest == 0 }, "interest-free ⇒ every interest slice is 0")
            XCTAssertTrue(schedule.allSatisfy { $0.payment == 100 }, "1200 / 12 = 100 flat")
            XCTAssertEqual(schedule.reduce(Decimal(0)) { $0 + $1.principal }, 1_200)
            XCTAssertEqual(schedule.last?.balanceAfter, 0)
        }
    }

    // MARK: - Final-payment residual absorption

    /// 100 RON over 3 months, interest-free: 100/3 = 33.33 doesn't divide evenly, so
    /// the first two rows are 33.33 and the FINAL row absorbs the residual (33.34)
    /// to make the principal slices sum to exactly 100.
    func testFinalPaymentAbsorbsResidual() {
        let schedule = AmortizationSchedule.schedule(
            principal: 100, annualRatePercent: nil, termMonths: 3,
            startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
        )
        XCTAssertEqual(schedule.count, 3)
        XCTAssertEqual(schedule[0].principal, dec("33.33"))
        XCTAssertEqual(schedule[1].principal, dec("33.33"))
        XCTAssertEqual(schedule[2].principal, dec("33.34"), "the final payment absorbs the rounding residual")
        XCTAssertEqual(schedule.reduce(Decimal(0)) { $0 + $1.principal }, 100, "still sums to exactly 100")
        XCTAssertEqual(schedule.last?.balanceAfter, 0)
    }

    // MARK: - Fixed monthly payment override

    /// A known fixed monthly payment overrides the computed annuity; the split is
    /// still interest = balance × rate, principal = payment − interest, and the
    /// final row clears the balance exactly.
    func testFixedMonthlyPaymentOverridesAnnuity() {
        let schedule = AmortizationSchedule.schedule(
            principal: 10_000, annualRatePercent: dec("12"), termMonths: 12,
            startDate: startDate(), fixedMonthlyPayment: dec("900"), calendar: bucharestCalendar()
        )
        XCTAssertFalse(schedule.isEmpty)
        XCTAssertEqual(schedule[0].payment, dec("900"), "the fixed payment is used, not the 888.49 annuity")
        XCTAssertEqual(schedule[0].interest, dec("100.00"))
        XCTAssertEqual(schedule[0].principal, dec("800.00"))
        XCTAssertEqual(schedule.last?.balanceAfter, 0, "the schedule still clears to zero")
        XCTAssertEqual(schedule.reduce(Decimal(0)) { $0 + $1.principal }, 10_000)
    }

    // MARK: - Degenerate inputs

    func testNoTermAndNoFixedPaymentYieldsEmptySchedule() {
        let schedule = AmortizationSchedule.schedule(
            principal: 10_000, annualRatePercent: dec("7.9"), termMonths: nil,
            startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
        )
        XCTAssertTrue(schedule.isEmpty, "no term and no fixed payment ⇒ cannot form a schedule")
    }

    func testNonPositivePrincipalYieldsEmptySchedule() {
        XCTAssertTrue(AmortizationSchedule.schedule(
            principal: 0, annualRatePercent: dec("12"), termMonths: 12,
            startDate: startDate(), fixedMonthlyPayment: nil, calendar: bucharestCalendar()
        ).isEmpty)
    }
}
