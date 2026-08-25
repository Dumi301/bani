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
/// (see `LiquidityCalculator.result`).
///
/// **v1.2b loan decision (no double-count).** Loan payments are modelled as
/// outgoing `ScheduledItem`s (see `LoanStore`), so they are ALREADY counted once
/// in `expectedOut` over the horizon. `loanAdjustment` therefore stays `.zero` on
/// every horizon path: adding a loan's outstanding balance here on top of the
/// payment items would double-count the same debt. The debt-position figures the
/// report needs ("sum owed left", "% left") are a SEPARATE balance-sheet
/// computation (`LoanStore.position`) that is never summed into `freeLiquidity`.
/// The seam is retained (non-zero-capable) only for a hypothetical surface that
/// represents a loan as a lump balance INSTEAD OF its payment items — the two
/// representations are mutually exclusive and must never both be active. Proven by
/// `LoanLiquidityTests`.
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
/// **v1.2b extension seam:** the `loanAdjustment` parameter can inject a net loan
/// balance into `freeLiquidity`. It defaults to `.zero` and STAYS `.zero` in
/// production: loan payments already flow through `pendingItems` → `expectedOut`
/// (they are ordinary outgoing `ScheduledItem`s minted by `LoanStore`), so each
/// payment is counted exactly once. Passing a loan's outstanding balance here as
/// well would double-count it. Debt-position numbers ("sum owed left" / "% left")
/// are computed separately by `LoanStore.position` and never added into
/// `freeLiquidity`. See `LoanLiquidityTests` for the no-double-count proof.
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
    /// - `loanAdjustment`: v1.2b seam (see type doc); leave at `.zero` — loan
    ///   payments are already counted via their `ScheduledItem`s in `expectedOut`,
    ///   so injecting a balance here would double-count (proven no-double-count in
    ///   `LoanLiquidityTests`).
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
