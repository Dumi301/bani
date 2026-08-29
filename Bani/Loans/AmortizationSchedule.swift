import Foundation

// MARK: - One scheduled payment

/// A single row of a loan's amortization schedule. Pure value type so the detail
/// table and every test hold it without a `ModelContext`. Money is ALWAYS
/// `Decimal`; each slice is rounded to 0.01 and `payment == interest + principal`
/// holds exactly for every row (including the residual-absorbing final one).
struct AmortizationPayment: Equatable, Sendable, Identifiable {
    /// 1-based payment number.
    let index: Int
    let dueDate: Date
    /// The total payment for this month (`interest + principal`).
    let payment: Decimal
    /// The interest slice = balance-before × monthlyRate (0 for interest-free).
    let interest: Decimal
    /// The principal slice = payment − interest; the final row absorbs the residual
    /// so the principal slices sum to exactly the original principal.
    let principal: Decimal
    /// Remaining balance AFTER this payment (0 on the final row).
    let balanceAfter: Decimal

    var id: Int { index }
}

// MARK: - Schedule result (rows + truncation flag)

/// The outcome of building an amortization schedule: the rows PLUS whether the
/// build had to force-collapse a degenerate loan (`AmortizationSchedule.schedule`
/// returns just `.rows` for the many callers that don't care).
///
/// `isTruncated` is the M5 defence-in-depth flag. It is `true` only when a fixed
/// monthly payment could not cover even the first period's interest, so the whole
/// remaining principal was dumped into a single row (the loan can never amortize).
/// In that case the reported `totalInterest` is a FLOOR — one month's interest —
/// and MASSIVELY understates the true lifetime cost of a non-amortizing loan.
/// `RaportHubModel` surfaces this flag so cost-of-capital is never silently wrong.
/// New loans can never be `isTruncated` (create/edit validation rejects them up
/// front — see `canAmortize`); the flag exists only to flag legacy stored data.
struct AmortizationScheduleResult: Equatable, Sendable {
    let rows: [AmortizationPayment]
    let isTruncated: Bool

    static let empty = AmortizationScheduleResult(rows: [], isTruncated: false)
}

// MARK: - Pure amortization math

/// Pure, unit-testable fixed-rate amortization — no `ModelContext`, no side
/// effects (`AmortizationScheduleTests`). Decimal throughout; the `Double` money
/// ban is absolute. The `LoanStore` payment-series generator and the live
/// interest/principal booking split both build on this, so the on-schedule table
/// and the actually-booked transactions agree to the cent.
///
/// Contract:
/// - Interest each month = `round(balance × monthlyRate, 0.01)`.
/// - Principal each month = `payment − interest`.
/// - The FINAL payment absorbs the rounding residual (its principal = the exact
///   remaining balance), so `Σ principal == principal` and
///   `Σ payment == principal + Σ interest` hold EXACTLY.
/// - `annualRatePercent == nil` or `0` ⇒ interest-free: every slice is principal.
enum AmortizationSchedule {

    /// A hard ceiling on generated rows so a degenerate input (e.g. a fixed
    /// payment that never covers the interest, with no term) can never loop
    /// forever. 1200 months = 100 years, well beyond any real loan.
    private static let maxMonths = 1200

    /// The per-month rate as a `Decimal` fraction (`percent / 100 / 12`), or `0`
    /// when interest-free. The single definition of "monthly rate" in the app.
    static func monthlyRate(annualRatePercent: Decimal?) -> Decimal {
        guard let percent = annualRatePercent, percent > 0 else { return 0 }
        return percent / 100 / 12
    }

    /// Round a `Decimal` money value to 0.01 (half away from zero, the banking
    /// default). Reused by `LoanStore` so booked splits match the schedule.
    static func rounded2(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    /// Integer power on `Decimal` (`base^exp`, `exp ≥ 0`) by repeated
    /// multiplication — avoids any `Double`/`pow` bridge, keeping the annuity
    /// factor exact to `Decimal`'s precision.
    static func power(_ base: Decimal, _ exp: Int) -> Decimal {
        var result: Decimal = 1
        var remaining = max(0, exp)
        var factor = base
        // Exponentiation by squaring — O(log exp) multiplications.
        while remaining > 0 {
            if remaining & 1 == 1 { result *= factor }
            remaining >>= 1
            if remaining > 0 { factor *= factor }
        }
        return result
    }

    /// The level annuity payment for `principal` at `monthlyRate` over `n` months,
    /// rounded to 0.01: `P·r·(1+r)^n / ((1+r)^n − 1)`. For `r == 0` it is the flat
    /// `principal / n`. Returns `nil` for a non-positive `n`.
    static func levelPayment(principal: Decimal, monthlyRate r: Decimal, months n: Int) -> Decimal? {
        guard n > 0 else { return nil }
        if r == 0 { return rounded2(principal / Decimal(n)) }
        let onePlusR = 1 + r
        let compound = power(onePlusR, n)          // (1+r)^n
        let denominator = compound - 1
        guard denominator != 0 else { return rounded2(principal / Decimal(n)) }
        return rounded2(principal * r * compound / denominator)
    }

    /// Build the full amortization schedule.
    ///
    /// Payment amount:
    /// - `fixedMonthlyPayment` (when > 0) overrides the computed annuity;
    /// - otherwise the level annuity payment over `termMonths` is used.
    ///
    /// Row count: `termMonths` when known; else (fixed payment, no term) the
    /// schedule runs until the balance clears (capped at `maxMonths`). The final
    /// row always drives the balance to exactly 0.
    ///
    /// Due dates advance one month at a time from `startDate` via
    /// `RecurrenceEngine` (DST-safe, month-end clamped) — the first payment falls
    /// one month after `startDate`.
    static func schedule(
        principal: Decimal,
        annualRatePercent: Decimal?,
        termMonths: Int?,
        startDate: Date,
        fixedMonthlyPayment: Decimal?,
        calendar: Calendar = .current
    ) -> [AmortizationPayment] {
        scheduleResult(
            principal: principal, annualRatePercent: annualRatePercent, termMonths: termMonths,
            startDate: startDate, fixedMonthlyPayment: fixedMonthlyPayment, calendar: calendar
        ).rows
    }

    /// The full build, exposing the M5 `isTruncated` flag alongside the rows. The
    /// row math is byte-identical to the historical `schedule(...)` (which now just
    /// takes `.rows`); the only addition is recording WHEN the degenerate
    /// below-interest collapse fired, so callers that book real money can tell a
    /// genuine schedule apart from a force-collapsed one.
    static func scheduleResult(
        principal: Decimal,
        annualRatePercent: Decimal?,
        termMonths: Int?,
        startDate: Date,
        fixedMonthlyPayment: Decimal?,
        calendar: Calendar = .current
    ) -> AmortizationScheduleResult {
        guard principal > 0 else { return .empty }
        let r = monthlyRate(annualRatePercent: annualRatePercent)

        // Resolve the level payment and an upper bound on the number of rows.
        let payment: Decimal
        let rowCap: Int
        if let fixed = fixedMonthlyPayment, fixed > 0 {
            payment = rounded2(fixed)
            rowCap = min(termMonths ?? maxMonths, maxMonths)
        } else if let months = termMonths, months > 0 {
            guard let p = levelPayment(principal: principal, monthlyRate: r, months: months) else { return .empty }
            payment = p
            rowCap = min(months, maxMonths)
        } else {
            // No fixed payment and no term ⇒ not enough to form a schedule.
            return .empty
        }
        guard payment > 0 else { return .empty }

        var rows: [AmortizationPayment] = []
        var balance = principal
        var due = startDate
        var index = 1
        var isTruncated = false

        while balance > 0 && index <= rowCap {
            due = RecurrenceEngine.nextDueDate(after: due, rule: .monthly, calendar: calendar) ?? due
            let interest = rounded2(balance * r)
            var principalSlice = payment - interest

            // Final-row detection: this is the last allowed row, or the scheduled
            // principal would clear (or overshoot) the balance. Absorb the residual
            // so Σ principal == principal exactly and balanceAfter == 0.
            let isLastAllowed = index == rowCap
            if principalSlice >= balance || isLastAllowed || (balance - principalSlice) <= 0 {
                principalSlice = balance
                let finalPayment = interest + principalSlice
                rows.append(AmortizationPayment(index: index, dueDate: due, payment: finalPayment,
                                                interest: interest, principal: principalSlice, balanceAfter: 0))
                balance = 0
                break
            }

            // Guard a degenerate fixed payment that never amortizes (payment ≤
            // interest): force progress by treating this as the final row. This is a
            // TRUNCATION — the reported totalInterest is only this one month's slice
            // and understates the real, non-amortizing loan; flag it so it is never
            // read as an honest cost.
            if principalSlice <= 0 {
                principalSlice = balance
                let finalPayment = interest + principalSlice
                rows.append(AmortizationPayment(index: index, dueDate: due, payment: finalPayment,
                                                interest: interest, principal: principalSlice, balanceAfter: 0))
                balance = 0
                isTruncated = true
                break
            }

            let newBalance = balance - principalSlice
            rows.append(AmortizationPayment(index: index, dueDate: due, payment: payment,
                                            interest: interest, principal: principalSlice, balanceAfter: newBalance))
            balance = newBalance
            index += 1
        }

        return AmortizationScheduleResult(rows: rows, isTruncated: isTruncated)
    }

    // MARK: - Create/edit validation (M5)

    /// The first period's interest = `round(principal × monthlyRate, 0.01)` — the
    /// exact amount a monthly payment must EXCEED to make any principal progress.
    static func firstPeriodInterest(principal: Decimal, annualRatePercent: Decimal?) -> Decimal {
        rounded2(principal * monthlyRate(annualRatePercent: annualRatePercent))
    }

    /// Whether a loan's terms can actually amortize. A fixed monthly payment that is
    /// ≤ the first period's interest can never reduce the principal, so the schedule
    /// would force-collapse and understate total interest — such a loan is rejected
    /// at create/edit (M5). The annuity path (no fixed payment) always amortizes by
    /// construction, and an interest-free loan (first-period interest 0) amortizes
    /// with any positive payment.
    static func canAmortize(principal: Decimal, annualRatePercent: Decimal?, fixedMonthlyPayment: Decimal?) -> Bool {
        guard let fixed = fixedMonthlyPayment, fixed > 0 else { return true }
        return rounded2(fixed) > firstPeriodInterest(principal: principal, annualRatePercent: annualRatePercent)
    }

    // MARK: - Derived totals

    /// Total interest paid across the whole schedule.
    static func totalInterest(_ schedule: [AmortizationPayment]) -> Decimal {
        schedule.reduce(0) { $0 + $1.interest }
    }

    /// Total of all payments (`principal + total interest`).
    static func totalPaid(_ schedule: [AmortizationPayment]) -> Decimal {
        schedule.reduce(0) { $0 + $1.payment }
    }
}
