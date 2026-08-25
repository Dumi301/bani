import Foundation

// MARK: - Value inputs

/// A logged transaction reduced to what reconciliation math needs — a pure value
/// type so all drift computation is unit-testable with no SwiftData (mirrors
/// `ProjectTxLine` / `ScheduledItemSnapshot`). Carries `direction` (sign of the
/// flow) and `date` (the economic date, which decides whether a flow lands before
/// or after an anchor's baseline).
struct ReconciliationFlow: Equatable, Sendable {
    var amount: Decimal
    var currency: Currency
    var direction: TransactionDirection
    var date: Date

    init(amount: Decimal, currency: Currency, direction: TransactionDirection, date: Date) {
        self.amount = amount
        self.currency = currency
        self.direction = direction
        self.date = date
    }
}

/// The baseline an expected balance is measured from: a recorded point of cash
/// truth in one currency at one instant. Value mirror of `BalanceAnchor`.
struct ReconciliationAnchor: Equatable, Sendable {
    var amount: Decimal
    var currency: Currency
    var anchoredAt: Date

    init(amount: Decimal, currency: Currency, anchoredAt: Date) {
        self.amount = amount
        self.currency = currency
        self.anchoredAt = anchoredAt
    }
}

// MARK: - Result

/// The assembled reconciliation picture for one entered actual balance. Pure value
/// type so views and tests hold it without a `ModelContext`.
struct ReconciliationResult: Equatable, Sendable {
    /// The currency the whole reconciliation is computed in (the anchor's currency,
    /// or the user-picked currency on a first reconcile).
    var currency: Currency
    /// The app's best estimate of the balance now: `baseline + net logged flows
    /// since the baseline` (neutral excluded, same-currency only — see `reconcile`).
    var expected: Decimal
    /// The real balance the client entered.
    var actual: Decimal
    /// `actual − expected`. Positive ⇒ you have MORE than logged (an unlogged
    /// income); negative ⇒ LESS (an unlogged expense / missed spend).
    var drift: Decimal
    /// The baseline amount used (`anchor.amount`, or `0` when no prior anchor of
    /// this currency existed — the first anchor establishes the baseline).
    var baseline: Decimal
    /// The net of the same-currency income/expense flows counted in the window
    /// (income `+`, expense `−`; neutral contributes `0`).
    var netLoggedSinceAnchor: Decimal
    /// Count of same-currency income/expense flows that moved `expected`.
    var countedFlows: Int
    /// Count of flows in a DIFFERENT currency than `currency`, deliberately skipped
    /// (never converted) so the drift stays exact against the account statement.
    /// A non-zero value drives the "drift excludes N foreign-currency flows" caption.
    var excludedCurrencyFlows: Int
    /// True when a prior anchor of this currency was used as the baseline.
    var hasAnchor: Bool

    /// The reconciliation is clean — nothing to adjust.
    var isBalanced: Bool { drift == 0 }

    /// The direction of the closing adjustment transaction, or `nil` when balanced.
    /// A negative drift (you have less than expected) closes with an `.expense`
    /// (it lowers the logged position to match reality); a positive drift closes
    /// with an `.income`.
    var adjustmentDirection: TransactionDirection? {
        if drift == 0 { return nil }
        return drift > 0 ? .income : .expense
    }

    /// The magnitude of the closing adjustment (always non-negative). `0` when
    /// balanced.
    var adjustmentAmount: Decimal { drift.magnitude }
}

// MARK: - Engine

/// Pure, `ModelContext`-free reconciliation of logged flows against a recorded real
/// balance. The same discipline as `LiquidityCalculator` / `ProjectAnalytics`:
/// deterministic, value-typed, unit-testable.
///
/// **Expected-balance model.** `expected = baseline + Σ signed(flow)` over the
/// flows dated *after* the baseline instant, where:
/// - `baseline` = the latest anchor's amount in this currency, or `0` when none
///   exists yet (the first reconcile establishes the baseline; its drift is the
///   whole gap between logged-from-zero and reality).
/// - `signed(flow)`: `.income → +amount`, `.expense → −amount`, `.neutral → 0`.
///
/// **Neutral / loan slices — "counted exactly as booked" (composes with P3).**
/// Neutral flows contribute `0`, *precisely* the "existing liquidity semantics" of
/// neutral: `ProjectAnalytics.netLoggedPosition` (the always-on-top portfolio
/// number and the acceptance target) excludes neutral, so reconciliation must too,
/// or the closing adjustment would over/undershoot that number. A booked loan
/// payment is an interest slice (`.expense`) + a principal slice (`.neutral`), so a
/// loan payment lowers the expected balance by exactly its interest — the same
/// amount it lowered `netLoggedPosition` by — and the neutral principal, already the
/// no-double-count basis of `LoanStore` / `LiquidityCalculator.loanAdjustment == 0`,
/// never registers as drift. No loan is special-cased: flows are summed by their
/// stored `direction`, and loan slices fall out correctly by construction.
///
/// **Multi-currency rule — same-currency only, never converted.** An anchor is a
/// real balance in ONE account's currency. `expected` is computed in that currency
/// by summing only flows of the SAME currency at face value. Flows in a different
/// currency are NOT converted (BNR conversion is display-only, per the existing
/// convention) — converting would inject rate noise into a number the client is
/// matching penny-for-penny against a bank statement. They are skipped and surfaced
/// via `excludedCurrencyFlows` so the UI can warn rather than silently guess. To
/// reconcile a EUR account, anchor in EUR; RON flows then count against the RON
/// anchor and EUR flows against the EUR anchor, each exact.
enum ReconciliationEngine {

    /// Net of the same-currency income/expense flows in the window, plus the counts
    /// the UI needs. `since == nil` ⇒ every flow (a first reconcile with no anchor);
    /// otherwise only flows with `date > since` (strict, so a closing adjustment
    /// dated at the anchor instant is part of the baseline, never re-counted).
    static func netLoggedFlows(
        _ flows: [ReconciliationFlow],
        currency: Currency,
        since: Date?
    ) -> (net: Decimal, counted: Int, excludedCurrency: Int) {
        var net: Decimal = 0
        var counted = 0
        var excluded = 0
        for flow in flows {
            if let since, flow.date <= since { continue }
            guard flow.currency == currency else {
                excluded += 1
                continue
            }
            switch flow.direction {
            case .income:
                net += flow.amount
                counted += 1
            case .expense:
                net -= flow.amount
                counted += 1
            case .neutral:
                break // excluded from the position, exactly like netLoggedPosition
            }
        }
        return (net, counted, excluded)
    }

    /// Reconcile an entered actual balance against the logged flows and the latest
    /// anchor of the same currency (or no anchor).
    ///
    /// - `anchor`: the baseline, or `nil` for a first-ever reconcile. When present
    ///   its `currency` MUST equal `currency` (the caller resolves the latest anchor
    ///   *of the target currency*); a mismatched anchor is ignored as if absent.
    static func reconcile(
        actual: Decimal,
        currency: Currency,
        anchor: ReconciliationAnchor?,
        flows: [ReconciliationFlow]
    ) -> ReconciliationResult {
        let usableAnchor = (anchor?.currency == currency) ? anchor : nil
        let baseline = usableAnchor?.amount ?? 0
        let rollup = netLoggedFlows(flows, currency: currency, since: usableAnchor?.anchoredAt)
        let expected = baseline + rollup.net
        let drift = actual - expected
        return ReconciliationResult(
            currency: currency,
            expected: expected,
            actual: actual,
            drift: drift,
            baseline: baseline,
            netLoggedSinceAnchor: rollup.net,
            countedFlows: rollup.counted,
            excludedCurrencyFlows: rollup.excludedCurrency,
            hasAnchor: usableAnchor != nil
        )
    }
}
