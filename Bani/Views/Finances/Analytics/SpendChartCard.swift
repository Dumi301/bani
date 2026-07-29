import SwiftUI
import Charts

/// The three interchangeable analytics chart types (D1). The choice is
/// remembered via `@AppStorage("financesChartType")` in `FinancesView`.
enum ChartKind: String, CaseIterable, Identifiable, Sendable {
    case donut
    case bars
    case line

    var id: String { rawValue }

    var label: String {
        switch self {
        case .donut: "Category"
        case .bars: "Over time"
        case .line: "Trend"
        }
    }

    /// SF Symbol for the segmented switcher.
    var symbol: String {
        switch self {
        case .donut: "chart.pie.fill"
        case .bars: "chart.bar.fill"
        case .line: "chart.line.uptrend.xyaxis"
        }
    }
}

/// The Finances analytics chart card (D1): a segmented chart-type switcher over
/// a donut-by-category / bars-over-time / cumulative-line view. Purely
/// presentational — every aggregate is computed by `FinancesAnalytics` in the
/// parent and passed in. Built with Apple Swift Charts (no third-party deps).
///
/// Swift Charts marks used: `SectorMark` (donut), `BarMark` + `RuleMark`
/// (bars + average line), `LineMark` (current vs previous trend).
struct SpendChartCard: View {
    @Binding var kind: ChartKind
    @Binding var selectedCategory: TransactionCategory?

    let categoryTotals: [FinancesAnalytics.CategoryTotal]
    let periodTotal: Decimal
    let buckets: [FinancesAnalytics.TimeBucket]
    let average: Decimal
    let bucketUnit: Calendar.Component
    let currentTrend: [FinancesAnalytics.CumulativePoint]
    let previousTrend: [FinancesAnalytics.CumulativePoint]
    let currencyCode: String

    @State private var selectedAngle: Double? = nil

    private var plotted: [FinancesAnalytics.CategoryTotal] {
        categoryTotals.filter { $0.total > 0 }
    }
    private var hasData: Bool { !plotted.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            Picker("Chart type", selection: $kind) {
                ForEach(ChartKind.allCases) { kind in
                    Image(systemName: kind.symbol)
                        .accessibilityLabel(kind.label)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("finances.chartTypePicker")

            chart
                .frame(height: 236)
                .id(kind)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

            if kind == .line && hasData {
                trendLegend
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: kind)
    }

    @ViewBuilder
    private var chart: some View {
        if !hasData {
            emptyChart
        } else {
            switch kind {
            case .donut: donut
            case .bars: bars
            case .line: line
            }
        }
    }

    // MARK: - Donut

    private var donut: some View {
        Chart(plotted) { item in
            SectorMark(
                angle: .value("Total", item.total.chartDouble),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(categoryColor(item.category))
            .opacity(selectedCategory == nil || selectedCategory == item.category ? 1 : 0.28)
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let frame = geo[anchor]
                    donutCenter
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .onChange(of: selectedAngle) { _, newValue in
            guard let newValue else { return }
            let tapped = category(atAngle: newValue)
            selectedCategory = (selectedCategory == tapped) ? nil : tapped
        }
        .accessibilityIdentifier("finances.donutChart")
    }

    private var donutCenter: some View {
        VStack(spacing: 1) {
            Text(selectedCategory?.label ?? "Total")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color("BaniSecondaryInk"))
            Text(centerTotal, format: .number.precision(.fractionLength(0)))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color("BaniInk"))
            Text(currencyCode)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
    }

    /// The center number: the selected slice's total, or the whole-period total.
    private var centerTotal: Decimal {
        if let selectedCategory {
            return plotted.first { $0.category == selectedCategory }?.total ?? 0
        }
        return periodTotal
    }

    /// Maps a tapped angular value (cumulative units) back to its category.
    private func category(atAngle value: Double) -> TransactionCategory? {
        var cumulative = 0.0
        for item in plotted {
            cumulative += item.total.chartDouble
            if value <= cumulative { return item.category }
        }
        return plotted.last?.category
    }

    // MARK: - Bars

    private var bars: some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Period", bucket.start, unit: bucketUnit),
                    y: .value("Spent", bucket.total.chartDouble)
                )
                .cornerRadius(3)
                .foregroundStyle(Color("BaniAccent").gradient)
            }
            if average > 0 {
                RuleMark(y: .value("Average", average.chartDouble))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg \(average, format: .number.precision(.fractionLength(0)))")
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Color("BaniSecondaryInk"))
                    }
            }
        }
        .chartYAxis { axisMarksY }
        .chartXAxis { AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) }
        .accessibilityIdentifier("finances.barsChart")
    }

    // MARK: - Line (current vs previous)

    private var line: some View {
        Chart {
            ForEach(previousTrend) { point in
                LineMark(
                    x: .value("Date", point.alignedDate),
                    y: .value("Cumulative", point.cumulative.chartDouble),
                    series: .value("Series", "Previous")
                )
                .foregroundStyle(Color("BaniSecondaryInk").opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .interpolationMethod(.monotone)
            }
            ForEach(currentTrend) { point in
                LineMark(
                    x: .value("Date", point.alignedDate),
                    y: .value("Cumulative", point.cumulative.chartDouble),
                    series: .value("Series", "This period")
                )
                .foregroundStyle(Color("BaniAccent"))
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartYAxis { axisMarksY }
        .chartXAxis { AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) }
        .accessibilityIdentifier("finances.lineChart")
    }

    private var trendLegend: some View {
        HStack(spacing: 16) {
            legendSwatch(color: Color("BaniAccent"), label: "This period", dashed: false)
            legendSwatch(color: Color("BaniSecondaryInk").opacity(0.6), label: "Previous", dashed: true)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(Color("BaniSecondaryInk"))
    }

    private func legendSwatch(color: Color, label: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: dashed ? 2 : 3)
                .opacity(dashed ? 0.7 : 1)
            Text(label)
        }
    }

    private var axisMarksY: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Color("BaniHairline").opacity(0.6))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(number, format: .number.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.system(size: 32))
                .foregroundStyle(Color("BaniSecondaryInk").opacity(0.5))
            Text("No spending in this period")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("finances.chartEmpty")
    }
}
