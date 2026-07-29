import SwiftUI
import SwiftData

/// Finances cluster root — a Revolut-style analytics tab (D). Top to bottom:
/// a Personal/Work/All segment, a timeframe picker (Week / Month / 6M / Year /
/// Custom), a period hero total (combined RON via the cached BNR rate, or
/// side-by-side per-currency when no rate has been fetched), a 3-way chart card
/// (donut / bars / line), a tappable category breakdown, and the grouped
/// transaction list. A native `.searchable` bar (C) filters everything; tapping
/// a donut slice or a breakdown row filters the list to that category.
///
/// Reads `RateService` (owned by Unit G) purely for display per
/// `pipeline/interfaces.md` — this view never triggers a fetch itself. All
/// aggregation is `Decimal` via `FinancesAnalytics`.
struct FinancesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RateService.self) private var rates

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    /// Learned rules feed the search's category-keyword resolution ("fuel" and
    /// "benzină" both surface fuel entries).
    @Query private var categoryRules: [CategoryRule]

    /// Persists only the last-chosen Personal/Work segment — "All" is never
    /// written here, so relaunching after "All" restores the prior choice.
    @AppStorage("financesLastContext") private var lastContextRaw: String = TransactionContext.personal.rawValue
    @AppStorage("financesGrouping") private var groupingRaw: String = TransactionGrouping.category.rawValue
    @AppStorage("financesTimeframe") private var timeframeRaw: String = TimeframePreset.month.rawValue
    @AppStorage("financesChartType") private var chartRaw: String = ChartKind.donut.rawValue
    /// Which currency the charts aggregate when NO BNR rate is cached (D3 fallback).
    @AppStorage("financesCurrencyToggle") private var currencyToggleRaw: String = Currency.ron.rawValue
    /// Custom-range endpoints (timeIntervalSince1970); 0 = unset.
    @AppStorage("financesCustomStart") private var customStart: Double = 0
    @AppStorage("financesCustomEnd") private var customEnd: Double = 0

    @State private var selectedFilter: FinancesFilter
    @State private var searchText: String = ""
    @State private var selectedCategory: TransactionCategory?
    @State private var recentlyDeleted: DeletedTransactionSnapshot?
    @State private var isCustomRangePresented = false

    init() {
        let last = UserDefaults.standard.string(forKey: "financesLastContext") ?? TransactionContext.personal.rawValue
        let context = TransactionContext(rawValue: last) ?? .personal
        _selectedFilter = State(initialValue: context == .work ? .work : .personal)
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    noDataView
                } else {
                    analyticsList
                }
            }
            .background(Color("BaniCanvas").ignoresSafeArea())
            .navigationTitle("Finances")
            .navigationDestination(for: Transaction.self) { transaction in
                TransactionDetailView(transaction: transaction)
            }
            .searchable(text: $searchText, prompt: "Search description, category, name")
            .overlay(alignment: .bottom) {
                if let recentlyDeleted {
                    undoToast(for: recentlyDeleted)
                }
            }
            .sheet(isPresented: $isCustomRangePresented) {
                CustomRangeSheet(
                    start: customStart > 0 ? Date(timeIntervalSince1970: customStart) : defaultCustomStart,
                    end: customEnd > 0 ? Date(timeIntervalSince1970: customEnd) : Date(),
                    onCancel: {
                        // Reverting an unconfigured custom pick lands back on Month.
                        if customInterval == nil { timeframeRaw = TimeframePreset.month.rawValue }
                    },
                    onApply: { start, end in
                        customStart = start.timeIntervalSince1970
                        customEnd = end.timeIntervalSince1970
                        timeframeRaw = TimeframePreset.custom.rawValue
                    }
                )
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: recentlyDeleted?.id)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedCategory)
        }
    }

    // MARK: - Main list

    private var analyticsList: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    segmentControl
                    timeframeControl
                    if isSearching { searchSummary }
                    hero
                    if displayRate == nil { currencyToggle }
                    chartCard
                    if !categoryTotals.isEmpty { breakdown }
                    listControls
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if listTransactions.isEmpty {
                Section {
                    filteredEmptyRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.transactions, id: \.id) { transaction in
                            NavigationLink(value: transaction) {
                                TransactionRow(transaction: transaction)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(transaction)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Color("BaniSurface"))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Controls

    private var segmentControl: some View {
        Picker("Context", selection: $selectedFilter) {
            ForEach(FinancesFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("financesSegmentControl")
        .onChange(of: selectedFilter) { _, newValue in
            switch newValue {
            case .personal: lastContextRaw = TransactionContext.personal.rawValue
            case .work: lastContextRaw = TransactionContext.work.rawValue
            case .all: break
            }
        }
    }

    private var timeframeControl: some View {
        VStack(spacing: 4) {
            Picker("Timeframe", selection: timeframeBinding) {
                ForEach(TimeframePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("finances.timeframePicker")

            Text(timeframeCaption)
                .font(.caption2)
                .foregroundStyle(Color("BaniSecondaryInk"))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var currencyToggle: some View {
        Picker("Currency", selection: currencyToggleBinding) {
            ForEach(Currency.allCases, id: \.self) { currency in
                Text(currency.displayCode).tag(currency)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("finances.currencyToggle")
    }

    private var listControls: some View {
        VStack(spacing: 8) {
            if let selectedCategory {
                HStack {
                    Label(selectedCategory.label, systemImage: selectedCategory.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(categoryColor(selectedCategory))
                    Spacer()
                    Button {
                        withAnimation { self.selectedCategory = nil }
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color("BaniSecondaryInk"))
                }
                .accessibilityIdentifier("finances.categoryFilterChip")
            }
            GroupingPicker(selection: groupingBinding)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let rate = displayRate {
            VStack(spacing: 6) {
                heroCombined
                    .accessibilityIdentifier("financesHeroTotal")
                Text(perCurrencyBreakdown(analyticsTransactions))
                    .font(.subheadline)
                    .foregroundStyle(Color("BaniSecondaryInk"))
                if let date = rates.bnrPublishingDate {
                    Text("1 EUR = \(rate.formatted(.number.precision(.fractionLength(2)))) RON · BNR \(date)")
                        .font(.caption2)
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 4) {
                Text("Spent this \(preset.label.lowercased())")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                HStack(spacing: 32) {
                    perCurrencyStat(currency: .ron)
                        .accessibilityIdentifier("financesRonTotal")
                    perCurrencyStat(currency: .eur)
                        .accessibilityIdentifier("financesEurTotal")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var heroCombined: some View {
        VStack(spacing: 2) {
            Text("Spent this \(preset.label.lowercased())")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color("BaniSecondaryInk"))
            (
                Text(periodTotal, format: .number.precision(.fractionLength(0...2)))
                    .font(.system(size: 42, design: .rounded).weight(.bold))
                + Text(" RON")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            )
            .monospacedDigit()
            .foregroundStyle(Color("BaniAccent"))
        }
    }

    private func perCurrencyStat(currency: Currency) -> some View {
        let total = analyticsTransactions
            .filter { $0.currency == currency }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return VStack(spacing: 4) {
            Text(total, format: .number.precision(.fractionLength(0...2)))
                .font(.system(size: 32, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color("BaniAccent"))
            Text(currency.displayCode)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
    }

    private func perCurrencyBreakdown(_ transactions: [Transaction]) -> String {
        let grouped = Dictionary(grouping: transactions, by: \.currency)
        let parts = Currency.allCases.compactMap { currency -> String? in
            guard let items = grouped[currency], !items.isEmpty else { return nil }
            let total = items.reduce(Decimal(0)) { $0 + $1.amount }
            return "\(total.formatted(.number.precision(.fractionLength(0...2)))) \(currency.displayCode)"
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    private var searchSummary: some View {
        HStack {
            Text("\(searchedTransactions.count) result\(searchedTransactions.count == 1 ? "" : "s")")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color("BaniInk"))
            Spacer()
            Text(perCurrencyBreakdown(searchedTransactions))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .accessibilityIdentifier("finances.searchSummary")
    }

    // MARK: - Chart + breakdown

    private var chartCard: some View {
        SpendChartCard(
            kind: chartKindBinding,
            selectedCategory: $selectedCategory,
            categoryTotals: categoryTotals,
            periodTotal: periodTotal,
            buckets: buckets,
            average: averageBucket,
            bucketUnit: preset.bucketUnit,
            currentTrend: currentTrend,
            previousTrend: previousTrend,
            currencyCode: currencyCode
        )
    }

    private var breakdown: some View {
        VStack(spacing: 0) {
            ForEach(categoryTotals) { item in
                Button {
                    toggleCategory(item.category)
                } label: {
                    CategoryBreakdownRow(
                        item: item,
                        fraction: FinancesAnalytics.fraction(of: item.total, periodTotal: periodTotal),
                        currencyCode: currencyCode,
                        isSelected: selectedCategory == item.category
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("finances.categoryBreakdown")
    }

    private func toggleCategory(_ category: TransactionCategory?) {
        guard let category else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedCategory = (selectedCategory == category) ? nil : category
        }
    }

    // MARK: - Empty states

    private var noDataView: some View {
        VStack(spacing: 16) {
            segmentControl
                .padding(.horizontal)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 40))
                    .foregroundStyle(Color("BaniSecondaryInk"))
                Text(emptyStateTitle)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color("BaniInk"))
                Text("Log a purchase from the Log tab and it will show up here, with a spending breakdown.")
                    .font(.subheadline)
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("financesEmptyState")
    }

    private var filteredEmptyRow: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : "calendar.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(Color("BaniSecondaryInk").opacity(0.6))
            Text(isSearching
                 ? "No matches for “\(trimmedQuery)”"
                 : "No spending in this \(preset.label.lowercased())")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color("BaniSecondaryInk"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("finances.filteredEmpty")
    }

    private var emptyStateIcon: String {
        switch selectedFilter {
        case .personal: "person.crop.circle"
        case .work: "briefcase.fill"
        case .all: "tray"
        }
    }

    private var emptyStateTitle: String {
        switch selectedFilter {
        case .personal: "No personal transactions yet"
        case .work: "No work transactions yet"
        case .all: "No transactions yet"
        }
    }

    // MARK: - Delete + undo

    private func delete(_ transaction: Transaction) {
        let snapshot = DeletedTransactionSnapshot(transaction)
        modelContext.delete(transaction)
        try? modelContext.save()
        withAnimation { recentlyDeleted = snapshot }

        let snapshotID = snapshot.id
        Task {
            try? await Task.sleep(for: .seconds(4))
            if recentlyDeleted?.id == snapshotID {
                withAnimation { recentlyDeleted = nil }
            }
        }
    }

    private func undoDelete() {
        guard let snapshot = recentlyDeleted else { return }
        let restored = Transaction(
            amount: snapshot.amount,
            currency: snapshot.currency,
            context: snapshot.context,
            category: snapshot.category,
            descriptionText: snapshot.descriptionText,
            merchant: snapshot.merchant,
            date: snapshot.date,
            rawTranscript: snapshot.rawTranscript,
            source: snapshot.source,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(restored)
        try? modelContext.save()
        withAnimation { recentlyDeleted = nil }
    }

    @ViewBuilder
    private func undoToast(for snapshot: DeletedTransactionSnapshot) -> some View {
        HStack {
            Text("Transaction deleted")
                .font(.subheadline)
                .foregroundStyle(Color("BaniInk"))
            Spacer()
            Button("Undo") { undoDelete() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color("BaniAccent"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color("BaniSurface"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color("BaniHairline"))
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Bindings

    private var groupingBinding: Binding<TransactionGrouping> {
        Binding(
            get: { TransactionGrouping(rawValue: groupingRaw) ?? .category },
            set: { groupingRaw = $0.rawValue }
        )
    }

    private var chartKindBinding: Binding<ChartKind> {
        Binding(
            get: { ChartKind(rawValue: chartRaw) ?? .donut },
            set: { chartRaw = $0.rawValue }
        )
    }

    private var timeframeBinding: Binding<TimeframePreset> {
        Binding(
            get: { preset },
            set: { newValue in
                timeframeRaw = newValue.rawValue
                if newValue == .custom { isCustomRangePresented = true }
            }
        )
    }

    private var currencyToggleBinding: Binding<Currency> {
        Binding(
            get: { currencyToggle },
            set: { currencyToggleRaw = $0.rawValue }
        )
    }

    // MARK: - Derived state

    private var calendar: Calendar { .current }
    private var preset: TimeframePreset { TimeframePreset(rawValue: timeframeRaw) ?? .month }
    private var currencyToggle: Currency { Currency(rawValue: currencyToggleRaw) ?? .ron }
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }
    private var displayRate: Double? { rates.rate }
    private var currencyCode: String { displayRate == nil ? currencyToggle.displayCode : Currency.ron.displayCode }
    private var defaultCustomStart: Date { calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date() }

    private var customInterval: DateInterval? {
        guard customStart > 0, customEnd > customStart else { return nil }
        return DateInterval(start: Date(timeIntervalSince1970: customStart), end: Date(timeIntervalSince1970: customEnd))
    }

    private var currentInterval: DateInterval {
        TimeframeRange.current(preset, reference: Date(), calendar: calendar, custom: customInterval)
    }
    private var previousInterval: DateInterval {
        TimeframeRange.previous(preset, current: currentInterval, calendar: calendar)
    }

    private var timeframeCaption: String {
        let interval = currentInterval
        let start = interval.start.formatted(.dateTime.day().month(.abbreviated))
        // The stored end is exclusive; show the inclusive last day.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let end = lastDay.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) – \(end)"
    }

    private var learnedSnapshots: [CategoryRuleSnapshot] {
        categoryRules
            .filter { $0.origin == .learned }
            .map { CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, origin: $0.origin, hitCount: $0.hitCount) }
    }

    // MARK: - Filter pipeline

    private var contextFiltered: [Transaction] {
        switch selectedFilter {
        case .personal: transactions.filter { $0.context == .personal }
        case .work: transactions.filter { $0.context == .work }
        case .all: transactions
        }
    }

    private func applySearch(_ input: [Transaction]) -> [Transaction] {
        let q = TransactionSearch.fold(trimmedQuery)
        guard !q.isEmpty else { return input }
        let categories = TransactionSearch.categoriesMatching(foldedQuery: q, learnedRules: learnedSnapshots)
        return input.filter { tx in
            TransactionSearch.matches(
                TransactionSearch.Fields(
                    descriptionText: tx.descriptionText,
                    rawTranscript: tx.rawTranscript,
                    merchant: tx.merchant,
                    category: tx.category
                ),
                foldedQuery: q,
                matchingCategories: categories
            )
        }
    }

    /// Context + timeframe + search — the set the analytics (hero, chart,
    /// breakdown) aggregate over. The selected-category filter is NOT applied
    /// here (it filters only the list below).
    private var searchedTransactions: [Transaction] {
        let interval = currentInterval
        let inWindow = contextFiltered.filter { $0.date >= interval.start && $0.date < interval.end }
        return applySearch(inWindow)
    }
    private var analyticsTransactions: [Transaction] { searchedTransactions }

    private var listTransactions: [Transaction] {
        guard let selectedCategory else { return searchedTransactions }
        return searchedTransactions.filter { $0.category == selectedCategory }
    }

    private var previousWindowTransactions: [Transaction] {
        let interval = previousInterval
        let inWindow = contextFiltered.filter { $0.date >= interval.start && $0.date < interval.end }
        return applySearch(inWindow)
    }

    private func spendItem(_ tx: Transaction) -> SpendItem {
        SpendItem(amount: tx.amount, currency: tx.currency, category: tx.category, date: tx.date)
    }

    /// Analytics items with the no-rate currency toggle applied.
    private var analyticsSpendItems: [SpendItem] {
        let base = analyticsTransactions
        let scoped = displayRate == nil ? base.filter { $0.currency == currencyToggle } : base
        return scoped.map(spendItem)
    }
    private var previousSpendItems: [SpendItem] {
        let base = previousWindowTransactions
        let scoped = displayRate == nil ? base.filter { $0.currency == currencyToggle } : base
        return scoped.map(spendItem)
    }

    // MARK: - Aggregates

    private var periodTotal: Decimal {
        FinancesAnalytics.combinedTotal(analyticsSpendItems, rate: displayRate)
    }
    private var categoryTotals: [FinancesAnalytics.CategoryTotal] {
        FinancesAnalytics.byCategory(analyticsSpendItems, rate: displayRate)
    }
    private var buckets: [FinancesAnalytics.TimeBucket] {
        FinancesAnalytics.buckets(analyticsSpendItems, interval: currentInterval, unit: preset.bucketUnit, calendar: calendar, rate: displayRate)
    }
    private var averageBucket: Decimal {
        FinancesAnalytics.average(buckets)
    }
    private var currentTrend: [FinancesAnalytics.CumulativePoint] {
        FinancesAnalytics.cumulative(analyticsSpendItems, rate: displayRate, isPrevious: false, displayShift: 0)
    }
    private var previousTrend: [FinancesAnalytics.CumulativePoint] {
        let shift = currentInterval.start.timeIntervalSince(previousInterval.start)
        return FinancesAnalytics.cumulative(previousSpendItems, rate: displayRate, isPrevious: true, displayShift: shift)
    }

    // MARK: - Grouping

    private var groups: [TransactionGroup] {
        makeGroups(from: listTransactions, grouping: groupingBinding.wrappedValue)
    }

    private func makeGroups(from transactions: [Transaction], grouping: TransactionGrouping) -> [TransactionGroup] {
        switch grouping {
        case .category:
            let dict = Dictionary(grouping: transactions) { $0.category }
            let orderedKeys: [TransactionCategory?] = TransactionCategory.allCases.map { TransactionCategory?.some($0) } + [TransactionCategory?.none]
            return orderedKeys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return TransactionGroup(
                    id: key?.rawValue ?? "uncategorized",
                    title: key?.label ?? "Uncategorized",
                    transactions: items
                )
            }

        case .month:
            let dict = Dictionary(grouping: transactions) { tx in
                calendar.dateInterval(of: .month, for: tx.date)?.start ?? tx.date
            }
            return dict.keys.sorted(by: >).map { monthStart in
                TransactionGroup(
                    id: monthStart.ISO8601Format(),
                    title: monthStart.formatted(.dateTime.month(.wide).year()),
                    transactions: dict[monthStart] ?? []
                )
            }

        case .merchant:
            let dict = Dictionary(grouping: transactions) { tx -> String? in
                (tx.merchant?.isEmpty == false) ? tx.merchant : nil
            }
            let keys = dict.keys.sorted { lhs, rhs in
                switch (lhs, rhs) {
                case (nil, nil): false
                case (nil, _): false
                case (_, nil): true
                default: (lhs ?? "") < (rhs ?? "")
                }
            }
            return keys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return TransactionGroup(
                    id: key ?? "no-merchant",
                    title: key ?? "No merchant",
                    transactions: items
                )
            }
        }
    }
}

// MARK: - Breakdown row

/// One tappable category breakdown row (D1): color dot + icon, label, total,
/// share of period, and count. Tapping filters the list to that category.
private struct CategoryBreakdownRow: View {
    let item: FinancesAnalytics.CategoryTotal
    let fraction: Double
    let currencyCode: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category?.systemImage ?? "square.grid.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(categoryColor(item.category))
                .frame(width: 30, height: 30)
                .background(categoryColor(item.category).opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(item.category?.label ?? "Uncategorized")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color("BaniInk"))
                Text("\(item.count) item\(item.count == 1 ? "" : "s") · \(Int((fraction * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(Color("BaniSecondaryInk"))
            }

            Spacer(minLength: 8)

            Text(item.total, format: .number.precision(.fractionLength(0...2)))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color("BaniInk"))
            Text(currencyCode)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? categoryColor(item.category).opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Custom range sheet

/// Two date pickers for the Custom timeframe (D1). Applies an inclusive range;
/// the end is stored as end-of-day so the last day's transactions are included.
private struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    let onCancel: () -> Void
    let onApply: (Date, Date) -> Void

    init(start: Date, end: Date, onCancel: @escaping () -> Void, onApply: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        self.onCancel = onCancel
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let calendar = Calendar.current
                        let startDay = calendar.startOfDay(for: start)
                        // Exclusive end = start of the day AFTER the chosen end day.
                        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
                        onApply(startDay, endExclusive)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Supporting types

private enum FinancesFilter: String, CaseIterable, Identifiable, Sendable {
    case personal, work, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personal: "Personal"
        case .work: "Work"
        case .all: "All"
        }
    }
}

private struct TransactionGroup: Identifiable {
    let id: String
    let title: String
    let transactions: [Transaction]
}

/// Captured field values of a deleted transaction so the undo toast can
/// recreate an equivalent record. SwiftData can't "un-delete" the same
/// instance once removed from the context, so undo inserts a fresh one.
private struct DeletedTransactionSnapshot {
    let id = UUID()
    let amount: Decimal
    let currency: Currency
    let context: TransactionContext
    let category: TransactionCategory?
    let descriptionText: String
    let merchant: String?
    let date: Date
    let rawTranscript: String?
    let source: TransactionSource
    let createdAt: Date

    init(_ transaction: Transaction) {
        amount = transaction.amount
        currency = transaction.currency
        context = transaction.context
        category = transaction.category
        descriptionText = transaction.descriptionText
        merchant = transaction.merchant
        date = transaction.date
        rawTranscript = transaction.rawTranscript
        source = transaction.source
        createdAt = transaction.createdAt
    }
}
