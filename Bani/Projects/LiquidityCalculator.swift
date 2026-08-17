import Foundation

// MARK: - Horizon

/// The forward window over which scheduled money is summed for the liquidity
/// answer. The portfolio header's segmented control offers 30 / 60 / 90 days.
enum LiquidityHorizon: Int, CaseIterable, Identifiable, Sendable {
    case days30 = 30
    case days60 = 60
    case days90 = 90

    var id: Int { rawValue }

    /// Day count, for the segmented-control label (formatted by the view so the
    /// number localizes via the active locale's number style).
    var dayCount: Int { rawValue }
}

// MARK: - Result

/// The assembled liquidity picture for one horizon. Pure value type so views and
/// tests can hold it without a `ModelContext`.
///
/// `freeLiquidity` is the client's decision number ("can I enter another
/// investment?"): what's logged, plus what's expected in, minus what's expected
/// out, over the chosen horizon. `loanAdjustment` is the **v1.2b extension seam**
/// (see `LiquidityCalculator.result`) — always `.zero` in v1.2a.
struct LiquidityResult: Equatable, Sendable {
    /// All-time income − expenses across everything, already converted to RON by
    /// the caller (the existing Finances totals logic, reused).
    var netLoggedPosition: Decimal
    /// Pending incoming within the horizon (overdue included), converted to RON.
    var expectedIn: Decimal
    /// Pending outgoing within the horizon (overdue included), converted to RON.
    var expectedOut: Decimal
    /// v1.2b injection point: net loan balances slot in here (positive = adds to
    /// free liquidity). Always `.zero` in v1.2a — nothing loan-shaped is computed.
    var loanAdjustment: Decimal
    /// The horizon this result was computed for (days).
    var horizonDays: Int
    /// True when at least one EUR item fell in the window but no BNR rate was
    /// available to convert it — the UI then shows the per-currency fallback and
    /// the "curs BNR" caption instead of a single guessed number.
    var hasUnconvertibleCurrency: Bool

    /// The liquidity answer: logged + expected-in − expected-out (+ loan seam).
    var freeLiquidity: Decimal {
        netLoggedPosition + expectedIn - expectedOut + loanAdjustment
    }

    /// The net *scheduled* swing over the horizon, independent of what's logged.
    var netExpected: Decimal { expectedIn - expectedOut }
}

// MARK: - Calculator

/// Pure, `ModelContext`-free assembly of the liquidity answer from a net logged
/// position and the pending scheduled items. Deterministic (window is measured in
/// seconds from `now`, so it is timezone-independent and unit-testable).
///
/// **v1.2b extension seam:** the `loanAdjustment` parameter is where the next run
/// injects net loan balances into `freeLiquidity`. It defaults to `.zero`; v1.2a
/// never passes a non-zero value and computes no loan logic. Do not pre-build it.
enum LiquidityCalculator {

    /// Assemble the liquidity result for one horizon.
    ///
    /// - `pendingItems`: candidate items; non-`pending` ones are ignored, so
    ///   callers may pass an unfiltered list. Items due on or before
    ///   `now + horizon` are counted, which **includes overdue** items
    ///   (`dueDate < now`) — an overdue outgoing is still a claim on cash and an
    ///   overdue incoming is still expected.
    /// - `rate`: EUR→RON (BNR), or `nil` if none has ever been fetched. EUR items
    ///   that cannot be converted are skipped and flag `hasUnconvertibleCurrency`.
    /// - `loanAdjustment`: v1.2b seam (see type doc); leave at `.zero`.
    static func result(
        netLoggedPosition: Decimal,
        pendingItems: [ScheduledItemSnapshot],
        horizon: LiquidityHorizon,
        rate: Decimal?,
        loanAdjustment: Decimal = .zero,
        now: Date = .now
    ) -> LiquidityResult {
        let endDate = now.addingTimeInterval(TimeInterval(horizon.rawValue) * 86_400)
        var inSum: Decimal = 0
        var outSum: Decimal = 0
        var unconvertible = false

        for item in pendingItems {
            guard item.status == .pending else { continue }
            // No lower bound → overdue (dueDate < now) is included by design.
            guard item.dueDate <= endDate else { continue }
            guard let ron = ronValue(of: item.amount, currency: item.currency, rate: rate) else {
                unconvertible = true
                continue
            }
            switch item.direction {
            case .incoming: inSum += ron
            case .outgoing: outSum += ron
            }
        }

        return LiquidityResult(
            netLoggedPosition: netLoggedPosition,
            expectedIn: inSum,
            expectedOut: outSum,
            loanAdjustment: loanAdjustment,
            horizonDays: horizon.rawValue,
            hasUnconvertibleCurrency: unconvertible
        )
    }

    /// Display-time RON conversion, mirroring `RateService.ronEquivalent`: RON
    /// passes through; EUR converts via `rate`, or returns `nil` (never a guessed
    /// rate) when none is available.
    static func ronValue(of amount: Decimal, currency: Currency, rate: Decimal?) -> Decimal? {
        switch currency {
        case .ron:
            return amount
        case .eur:
            guard let rate else { return nil }
            return amount * rate
        }
    }
}
