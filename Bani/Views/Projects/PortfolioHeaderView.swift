import SwiftUI

/// The always-on-top liquidity answer for the Projects tab. Net logged position
/// (all-time income − expenses across everything), expected in / out over a
/// selectable 30 / 60 / 90-day horizon, and the free-liquidity line — the number
/// that answers "can I enter another investment?".
struct PortfolioHeaderView: View {
    @Environment(\.metrics) private var metrics

    let netLoggedPosition: Decimal
    let liquidity: LiquidityResult
    @Binding var horizon: LiquidityHorizon
    let bnrDate: String?
    let rate: Double?

    /// v2 — presents the balance-reconciliation sheet (enter real balance → drift →
    /// adjust / anchor). Self-contained here so no shared surface is touched.
    @State private var showingReconcile = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            Text("portfolio.netPosition")
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.secondaryInk)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(netLoggedPosition, format: .number.precision(.fractionLength(0...2)))
                    .font(Typography.heroAmount)
                    .foregroundStyle(netLoggedPosition < 0 ? Palette.secondaryInk : Palette.accent)
                Text(Currency.ron.displayCode)
                    .font(Typography.amount(.title3, weight: .semibold))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .accessibilityIdentifier("portfolio.netPosition")

            horizonPicker

            HStack(spacing: metrics.sectionSpacing) {
                expectedStat(labelKey: "portfolio.expectedIn", value: liquidity.expectedIn, sign: "+")
                expectedStat(labelKey: "portfolio.expectedOut", value: liquidity.expectedOut, sign: "−")
            }

            Divider().background(Palette.hairline)

            // Free liquidity — the decision number.
            HStack(alignment: .firstTextBaseline) {
                Text("portfolio.freeLiquidity")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(liquidity.freeLiquidity.formatted(.number.precision(.fractionLength(0...2)))) \(Currency.ron.displayCode)")
                    .font(Typography.amount(.title3, weight: .bold))
                    .foregroundStyle(liquidity.freeLiquidity < 0 ? Palette.secondaryInk : Palette.accent)
            }
            .accessibilityIdentifier("portfolio.freeLiquidity")

            captionLine

            reconcileButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .sheet(isPresented: $showingReconcile) {
            ReconciliationSheet()
        }
    }

    /// Entry point to the reconciliation flow — "my actual balance is…" resets the
    /// drift baseline so a missed expense can never corrupt the number forever.
    private var reconcileButton: some View {
        Button {
            showingReconcile = true
        } label: {
            Label("reconcile.cta", systemImage: "scalemass")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: DesignMetrics.minTapTarget)
        }
        .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button))
        .foregroundStyle(Palette.accent)
        .accessibilityIdentifier("portfolio.reconcileButton")
    }

    private var horizonPicker: some View {
        Picker("portfolio.horizon", selection: $horizon) {
            ForEach(LiquidityHorizon.allCases) { h in
                Text(verbatim: "\(h.dayCount)").tag(h)
            }
        }
        .pickerStyle(.segmented)
        .tint(Palette.accent)
        .accessibilityIdentifier("portfolio.horizonPicker")
    }

    private func expectedStat(labelKey: LocalizedStringKey, value: Decimal, sign: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(labelKey)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.secondaryInk)
            Text("\(sign)\(value.formatted(.number.precision(.fractionLength(0...2)))) \(Currency.ron.displayCode)")
                .font(Typography.amount(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var captionLine: some View {
        if liquidity.hasUnconvertibleCurrency {
            Text("portfolio.noRate")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
        } else if let rate, let bnrDate {
            Text("1 EUR = \(rate.formatted(.number.precision(.fractionLength(2)))) RON · BNR \(bnrDate)")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
        }
    }
}
