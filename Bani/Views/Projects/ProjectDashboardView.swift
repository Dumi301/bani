import SwiftUI
import SwiftData

/// A project's Dashboard pane: the SAME Finances analytics, scoped by `projectID`
/// — the shared `SpendChartCard` + `FinancesAnalytics` engine, not a fork. Donut /
/// bars / trend over this project's expenses, a native RON-vs-EUR currency-split
/// row (before conversion), a category breakdown, and a searchable list of the
/// project's transactions.
struct ProjectDashboardView: View {
    @Environment(RateService.self) private var rates
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale

    let projectID: UUID

    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @Query private var customCategories: [CustomCategory]

    @State private var chartKind: ChartKind = .donut
    @State private var selectedRef: CategoryRef?
    @State private var selectedBucket: FinancesAnalytics.TimeBucket?
    @State private var searchText: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: metrics.sectionSpacing) {
                if projectTransactions.isEmpty {
                    emptyState
                } else {
                    currencySplitRow
                    SpendChartCard(
                        kind: $chartKind,
                        selectedRef: $selectedRef,
                        selectedBucket: $selectedBucket,
                        categoryTotals: categoryTotals,
                        periodTotal: periodTotal,
                        buckets: buckets,
                        average: FinancesAnalytics.average(buckets),
                        bucketUnit: .month,
                        currentTrend: currentTrend,
                        previousTrend: [],
                        currencyCode: currencyCode,
                        customs: customLookup
                    )
                    if !categoryTotals.isEmpty { breakdown }
                    transactionList
                }
            }
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.elementSpacing)
        }
        .searchable(text: $searchText, prompt: Text("finances.searchPrompt"))
    }

    // MARK: - Currency split (native, before conversion)

    private var currencySplitRow: some View {
        let byCurrency = ProjectAnalytics.totalsByCurrency(scopedLines)
        return HStack {
            ForEach(Currency.allCases, id: \.self) { currency in
                let total = byCurrency[currency] ?? 0
                if total > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currency.displayCode)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.secondaryInk)
                        Text(total, format: .number.precision(.fractionLength(0...2)))
                            .font(Typography.amount(.subheadline, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("project.dashboard.currencySplit")
    }

    // MARK: - Breakdown

    private var breakdown: some View {
        VStack(spacing: 6) {
            ForEach(categoryTotals) { item in
                let style = categoryStyle(item.categoryRef, customs: customLookup)
                HStack(spacing: metrics.elementSpacing) {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(style.color)
                        .frame(width: 28, height: 28)
                        .background(Palette.canvas, in: Circle())
                    Text(style.label)
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(item.total.formatted(.number.precision(.fractionLength(0...2)))) \(currencyCode)")
                        .font(Typography.amount(.subheadline, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("project.dashboard.breakdown")
    }

    // MARK: - Transaction list

    private var transactionList: some View {
        VStack(spacing: metrics.rowSpacing) {
            ForEach(searchedTransactions, id: \.id) { tx in
                NavigationLink(value: tx) {
                    TransactionRow(transaction: tx, customs: customLookup)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("project.dashboard.list")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie")
                .font(.system(size: 34))
                .foregroundStyle(Palette.secondaryInk)
            Text("project.dashboard.empty")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("project.dashboard.emptyState")
    }

    // MARK: - Derived

    private var customLookup: CustomCategoryLookup { customCategories.lookup }
    // L5: the exact Decimal rate (`RateService.rateDecimal`), not
    // `rates.rate.map { Decimal($0) }` — see `RateService`'s doc. `displayRate`
    // (the Double mirror) was dropped here once every local FinancesAnalytics/
    // ProjectAnalytics call site moved onto this exact Decimal source.
    private var rateDecimal: Decimal? { rates.rateDecimal }
    private var currencyCode: String { Currency.ron.displayCode }

    private var projectTransactions: [Transaction] {
        allTransactions.filter { $0.projectID == projectID }
    }

    private var scopedLines: [ProjectTxLine] {
        projectTransactions.map {
            ProjectTxLine(amount: $0.amount, currency: $0.currency, direction: $0.direction,
                          projectID: $0.projectID, date: $0.date)
        }
    }

    private var searchedTransactions: [Transaction] {
        let q = TransactionSearch.fold(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return projectTransactions }
        return projectTransactions.filter { tx in
            TransactionSearch.matches(
                TransactionSearch.Fields(
                    descriptionText: tx.descriptionText,
                    rawTranscript: tx.rawTranscript,
                    merchant: tx.merchant,
                    counterparty: tx.counterparty,
                    category: tx.category,
                    customCategoryID: tx.customCategoryID
                ),
                foldedQuery: q,
                matchingCategories: [],
                matchingCustoms: []
            )
        }
    }

    /// Expenses only (charts aggregate spending), as SpendItems.
    private var spendItems: [SpendItem] {
        projectTransactions
            .filter { $0.direction == .expense }
            .map { SpendItem(amount: $0.amount, currency: $0.currency, category: $0.category, customCategoryID: $0.customCategoryID, date: $0.date) }
    }

    private var periodTotal: Decimal { FinancesAnalytics.combinedTotal(spendItems, rate: rateDecimal) }
    private var categoryTotals: [FinancesAnalytics.CategoryTotal] { FinancesAnalytics.byCategory(spendItems, rate: rateDecimal) }

    /// All-time interval spanning the project's expenses (monthly buckets).
    private var interval: DateInterval {
        let dates = spendItems.map(\.date)
        let start = dates.min() ?? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: dates.max() ?? Date()) ?? Date()
        return DateInterval(start: min(start, end), end: max(start, end).addingTimeInterval(1))
    }

    private var buckets: [FinancesAnalytics.TimeBucket] {
        FinancesAnalytics.buckets(spendItems, interval: interval, unit: .month, calendar: .current, rate: rateDecimal)
    }
    private var currentTrend: [FinancesAnalytics.CumulativePoint] {
        FinancesAnalytics.cumulative(spendItems, rate: rateDecimal, isPrevious: false, displayShift: 0)
    }
}
