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
    /// The in-app language locale (B3) — applied to every String-producing
    /// FormatStyle below so dates/numbers follow the chosen language.
    @Environment(\.locale) private var locale
    /// Active density (B1) — drives every spacing/padding token below.
    @Environment(\.metrics) private var metrics

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    /// Learned rules feed the search's category-keyword resolution ("fuel" and
    /// "benzină" both surface fuel entries).
    @Query private var categoryRules: [CategoryRule]
    /// User-defined categories (C3) — resolved into the charts, breakdown,
    /// grouping, search and the filter chips as full first-class citizens.
    @Query private var customCategories: [CustomCategory]

    /// Persists only the last-chosen Personal/Work segment — "All" is never
    /// written here, so relaunching after "All" restores the prior choice.
    @AppStorage("financesLastContext") private var lastContextRaw: String = TransactionContext.personal.rawValue
    @AppStorage("financesGrouping") private var groupingRaw: String = TransactionGrouping.category.rawValue
    @AppStorage("financesTimeframe") private var timeframeRaw: String = TimeframePreset.month.rawValue
    @AppStorage("financesChartType") private var chartRaw: String = ChartKind.donut.rawValue
    /// Which currency the charts aggregate when NO BNR rate is cached (D3 fallback).
    @AppStorage("financesCurrencyToggle") private var currencyToggleRaw: String = Currency.ron.rawValue
    /// A3 — the hero shows spending (default) or net (income − spending), remembered.
    @AppStorage("financesHeroMode") private var heroModeRaw: String = HeroMode.spent.rawValue
    /// Custom-range endpoints (timeIntervalSince1970); 0 = unset.
    @AppStorage("financesCustomStart") private var customStart: Double = 0
    @AppStorage("financesCustomEnd") private var customEnd: Double = 0

    @State private var selectedFilter: FinancesFilter
    @State private var searchText: String = ""
    /// The shared category filter seam (donut slice / breakdown row) — a preset
    /// OR a custom category (C3). Filters ONLY the list below, not the charts.
    @State private var selectedRef: CategoryRef?
    /// The shared bucket filter seam (A3): tapping a bar filters the list to that
    /// bucket's date range. Composes with `selectedRef`; both surface as chips.
    @State private var selectedBucket: FinancesAnalytics.TimeBucket?
    @State private var recentlyDeleted: DeletedTransactionSnapshot?
    @State private var isCustomRangePresented = false

    /// v2 teardown: when `false`, this view is being PUSHED inside an ancestor
    /// `NavigationStack` (the Raport hub) rather than rooting its own tab. It then
    /// drops its own `NavigationStack` AND its `Transaction`/`PersonRoute`
    /// destinations, relying on the ancestor's single registration — the surgical
    /// change that turns the old tab-root Finances view into a reusable drill-down.
    /// Defaults to `true` so any standalone use is unchanged.
    let embedInNavigationStack: Bool

    init(embedInNavigationStack: Bool = true) {
        self.embedInNavigationStack = embedInNavigationStack
        let last = UserDefaults.standard.string(forKey: "financesLastContext") ?? TransactionContext.personal.rawValue
        let context = TransactionContext(rawValue: last) ?? .personal
        _selectedFilter = State(initialValue: context == .work ? .work : .personal)
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { financesContent }
        } else {
            financesContent
        }
    }

    private var financesContent: some View {
        Group {
            if transactions.isEmpty {
                noDataView
            } else {
                analyticsList
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("Finances")
        // Registered here ONLY when this view roots its own stack; when embedded the
        // Raport hub provides the shared Transaction/PersonRoute destinations.
        .modifier(FinancesNavigationDestinations(enabled: embedInNavigationStack))
        .searchable(text: $searchText, prompt: Text("finances.searchPrompt"))
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
        .animation(Motion.card, value: recentlyDeleted?.id)
        .animation(Motion.spring, value: selectedRef)
        .animation(Motion.spring, value: selectedBucket?.start)
        // A stale bucket filter can't survive a change of window / segment /
        // search — its date range would no longer line up with any bar.
        .onChange(of: timeframeRaw) { _, _ in selectedBucket = nil }
        .onChange(of: selectedFilter) { _, _ in selectedBucket = nil }
        .onChange(of: searchText) { _, _ in selectedBucket = nil }
        .onChange(of: customStart) { _, _ in selectedBucket = nil }
        .onChange(of: customEnd) { _, _ in selectedBucket = nil }
    }

    /// id → snapshot lookup for resolving custom categories in this render.
    private var customLookup: CustomCategoryLookup { customCategories.lookup }

    // MARK: - Localized period phrasing (word order differs per language, so each
    // timeframe is a whole phrase rather than "Spent this " + a lowercased word).

    private var spentThisPeriodText: String {
        switch preset {
        case .week: String(localized: "finances.spent.week")
        case .month: String(localized: "finances.spent.month")
        case .sixMonths: String(localized: "finances.spent.sixMonths")
        case .year: String(localized: "finances.spent.year")
        case .custom: String(localized: "finances.spent.custom")
        }
    }

    private var noSpendingText: String {
        switch preset {
        case .week: String(localized: "finances.noSpending.week")
        case .month: String(localized: "finances.noSpending.month")
        case .sixMonths: String(localized: "finances.noSpending.sixMonths")
        case .year: String(localized: "finances.noSpending.year")
        case .custom: String(localized: "finances.noSpending.custom")
        }
    }

    // MARK: - Main list

    private var analyticsList: some View {
        List {
            Section {
                VStack(spacing: metrics.sectionSpacing) {
                    segmentControl
                    timeframeControl
                    if isSearching { searchSummary }
                    hero
                    if displayRate == nil { currencyToggleControl }
                    chartCard
                    if !categoryTotals.isEmpty { breakdown }
                    listControls
                }
                .listRowInsets(EdgeInsets(top: metrics.elementSpacing, leading: metrics.screenPadding,
                                          bottom: metrics.elementSpacing, trailing: metrics.screenPadding))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if groupingBinding.wrappedValue == .people {
                peopleSections
            } else if listTransactions.isEmpty {
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
                                TransactionRow(transaction: transaction, customs: customLookup)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(transaction)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Palette.surface)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear {
            // Screenshot seam (A4): pre-select the latest bar so its highlight +
            // dismissible bucket chip render deterministically.
            if ProcessInfo.processInfo.arguments.contains("-uiTestBars"), selectedBucket == nil {
                selectedBucket = buckets.last
            }
        }
    }

    // MARK: - Controls

    private var segmentControl: some View {
        Picker("Context", selection: $selectedFilter) {
            ForEach(FinancesFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .tint(Palette.accent)
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
            .tint(Palette.accent)
            .accessibilityIdentifier("finances.timeframePicker")

            Text(timeframeCaption)
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var currencyToggleControl: some View {
        Picker("Currency", selection: currencyToggleBinding) {
            ForEach(Currency.allCases, id: \.self) { currency in
                Text(currency.displayCode).tag(currency)
            }
        }
        .pickerStyle(.segmented)
        .tint(Palette.accent)
        .accessibilityIdentifier("finances.currencyToggle")
    }

    private var listControls: some View {
        VStack(spacing: metrics.elementSpacing) {
            if selectedRef != nil || selectedBucket != nil {
                HStack(spacing: metrics.elementSpacing) {
                    if let selectedRef {
                        let style = categoryStyle(selectedRef, customs: customLookup)
                        filterChip(label: style.label, systemImage: style.systemImage, color: style.color) {
                            withAnimation { self.selectedRef = nil }
                        }
                        .accessibilityIdentifier("finances.categoryFilterChip")
                    }
                    if let selectedBucket {
                        filterChip(label: bucketChipLabel(selectedBucket), systemImage: "calendar", color: Palette.accent) {
                            withAnimation { self.selectedBucket = nil }
                        }
                        .accessibilityIdentifier("finances.bucketFilterChip")
                    }
                    Spacer(minLength: 0)
                }
            }
            GroupingPicker(selection: groupingBinding)
        }
    }

    /// A dismissible active-filter chip (A3): a brushed-metal chip whose accent /
    /// category-colored border + text signal the live (selected) filter; the ✕ clears it.
    private func filterChip(label: String, systemImage: String, color: Color, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(label).lineLimit(1)
                Image(systemName: "xmark.circle.fill").opacity(0.7)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, metrics.elementSpacing)
            .padding(.vertical, 5)
            .metalSurface(cornerRadius: Radius.chip)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(color.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// The bucket chip's label — a day for short windows, a full month for long
    /// ones — locale-aware so it follows the chosen in-app language.
    private func bucketChipLabel(_ bucket: FinancesAnalytics.TimeBucket) -> String {
        switch preset.bucketUnit {
        case .day: return bucket.start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        default: return bucket.start.formatted(.dateTime.month(.wide).year().locale(locale))
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let rate = displayRate {
            VStack(spacing: metrics.elementSpacing) {
                if hasIncome { heroModeControl }
                heroCombined
                    .accessibilityIdentifier("financesHeroTotal")
                if hasIncome { incomeLine }
                Text(perCurrencyBreakdown(expenseTransactions))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                if let date = rates.bnrPublishingDate {
                    Text("1 EUR = \(rate.formatted(.number.precision(.fractionLength(2)))) RON · BNR \(date)")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(metrics.cardPadding)
            .metalSurface(cornerRadius: Radius.card, elevated: true)
        } else {
            VStack(spacing: metrics.elementSpacing) {
                Text(spentThisPeriodText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                HStack(spacing: 32) {
                    perCurrencyStat(currency: .ron)
                        .accessibilityIdentifier("financesRonTotal")
                    perCurrencyStat(currency: .eur)
                        .accessibilityIdentifier("financesEurTotal")
                }
                if hasIncome { incomeLine }
            }
            .frame(maxWidth: .infinity)
            .padding(metrics.cardPadding)
            .metalSurface(cornerRadius: Radius.card, elevated: true)
        }
    }

    /// A3 — spent / net segmented toggle on the hero (shown only with a rate, so
    /// income and spending are combinable into one net figure). Remembered.
    private var heroModeControl: some View {
        Picker("Hero mode", selection: heroModeBinding) {
            ForEach(HeroMode.allCases) { mode in Text(mode.label).tag(mode) }
        }
        .pickerStyle(.segmented)
        .tint(Palette.accent)
        .fixedSize()
        .accessibilityIdentifier("finances.heroModeToggle")
    }

    /// A3 — the secondary income line, shown whenever the period has any income.
    private var incomeLine: some View {
        Text("finances.incomeLine \(incomeAmountText)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.accent)
            .accessibilityIdentifier("finances.incomeLine")
    }

    private var incomeAmountText: String {
        let code = displayRate == nil ? currencyToggle.displayCode : Currency.ron.displayCode
        return "\(incomeTotal.formatted(.number.precision(.fractionLength(0...2)))) \(code)"
    }

    private var heroCombined: some View {
        VStack(spacing: 2) {
            Text(heroCaption)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.secondaryInk)
            (
                Text(heroValue, format: .number.precision(.fractionLength(0...2)))
                    .font(Typography.heroAmount)
                + Text(" RON")
                    .font(Typography.amount(.title3, weight: .semibold))
            )
            .foregroundStyle(heroColor)
        }
    }

    private var heroCaption: String { heroMode == .net ? String(localized: "finances.net") : spentThisPeriodText }
    private var heroValue: Decimal { heroMode == .net ? netTotal : periodTotal }
    private var heroColor: Color { (heroMode == .net && netTotal < 0) ? Palette.secondaryInk : Palette.accent }

    private func perCurrencyStat(currency: Currency) -> some View {
        let total = expenseTransactions
            .filter { $0.currency == currency }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return VStack(spacing: 4) {
            Text(total, format: .number.precision(.fractionLength(0...2)))
                .font(Typography.amount(.largeTitle, weight: .bold))
                .foregroundStyle(Palette.accent)
            Text(currency.displayCode)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
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
            Text(CountLabels.results(searchedTransactions.count))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            Text(perCurrencyBreakdown(searchedTransactions))
                .font(Typography.mono(.footnote))
                .foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, metrics.cardPadding)
        .padding(.vertical, metrics.rowVInset)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("finances.searchSummary")
    }

    // MARK: - Chart + breakdown

    private var chartCard: some View {
        SpendChartCard(
            kind: chartKindBinding,
            selectedRef: $selectedRef,
            selectedBucket: $selectedBucket,
            categoryTotals: categoryTotals,
            periodTotal: periodTotal,
            buckets: buckets,
            average: averageBucket,
            bucketUnit: preset.bucketUnit,
            currentTrend: currentTrend,
            previousTrend: previousTrend,
            currencyCode: currencyCode,
            customs: customLookup
        )
    }

    private var breakdown: some View {
        VStack(spacing: 0) {
            ForEach(categoryTotals) { item in
                Button {
                    toggleRef(item.categoryRef)
                } label: {
                    CategoryBreakdownRow(
                        item: item,
                        style: categoryStyle(item.categoryRef, customs: customLookup),
                        fraction: FinancesAnalytics.fraction(of: item.total, periodTotal: periodTotal),
                        currencyCode: currencyCode,
                        isSelected: selectedRef == item.categoryRef
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(metrics.elementSpacing)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("finances.categoryBreakdown")
    }

    private func toggleRef(_ ref: CategoryRef?) {
        guard let ref else { return }
        withAnimation(Motion.spring) {
            selectedRef = (selectedRef == ref) ? nil : ref
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
                    .foregroundStyle(Palette.secondaryInk)
                Text(emptyStateTitle)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text("Log a purchase from the Log tab and it will show up here, with a spending breakdown.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
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
                .foregroundStyle(Palette.secondaryInk.opacity(0.6))
            Text(isSearching
                 ? String(localized: "finances.noMatches \(trimmedQuery)")
                 : noSpendingText)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
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
        case .personal: String(localized: "finances.empty.personal")
        case .work: String(localized: "finances.empty.work")
        case .all: String(localized: "finances.empty.all")
        }
    }

    // MARK: - Delete + undo

    private func delete(_ transaction: Transaction) {
        let snapshot = DeletedTransactionSnapshot(transaction)
        modelContext.delete(transaction)
        try? modelContext.save()
        withAnimation(Motion.card) { recentlyDeleted = snapshot }

        let snapshotID = snapshot.id
        let attachmentID = snapshot.attachmentID
        Task {
            try? await Task.sleep(for: .seconds(4))
            if recentlyDeleted?.id == snapshotID {
                withAnimation(Motion.card) { recentlyDeleted = nil }
                // The undo window elapsed — the delete is permanent, so drop the
                // imported-document attachment file too (E2).
                if let attachmentID { AttachmentStore.delete(id: attachmentID) }
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
            customCategoryID: snapshot.customCategoryID,
            descriptionText: snapshot.descriptionText,
            merchant: snapshot.merchant,
            date: snapshot.date,
            rawTranscript: snapshot.rawTranscript,
            source: snapshot.source,
            direction: snapshot.direction,
            counterparty: snapshot.counterparty,
            attachmentID: snapshot.attachmentID,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(restored)
        try? modelContext.save()
        withAnimation(Motion.card) { recentlyDeleted = nil }
    }

    @ViewBuilder
    private func undoToast(for snapshot: DeletedTransactionSnapshot) -> some View {
        HStack {
            Text("Transaction deleted")
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
            Spacer()
            Button("Undo") { undoDelete() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, metrics.cardPadding)
        .padding(.vertical, metrics.rowVInset)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
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
    // L5: the exact Decimal rate (`RateService.rateDecimal`) — the source every
    // `FinancesAnalytics` call below uses, not `displayRate.map { Decimal($0) }`
    // (the binary-float-noise conversion this fix removes). `displayRate` itself
    // stays `Double`-typed: it only ever feeds nil-checks and "1 EUR = …" text.
    private var rateDecimal: Decimal? { rates.rateDecimal }
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
        let start = interval.start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        // The stored end is exclusive; show the inclusive last day.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let end = lastDay.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        return "\(start) – \(end)"
    }

    private var learnedSnapshots: [CategoryRuleSnapshot] {
        categoryRules
            .filter { $0.origin == .learned }
            .map { CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, customCategoryID: $0.customCategoryID, origin: $0.origin, hitCount: $0.hitCount) }
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
        let customs = TransactionSearch.customCategoriesMatching(
            foldedQuery: q,
            customCategories: customCategories.map(\.snapshot),
            learnedRules: learnedSnapshots
        )
        return input.filter { tx in
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
                matchingCategories: categories,
                matchingCustoms: customs
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

    /// A3 direction split. Charts + the spending hero aggregate EXPENSES only;
    /// income drives the secondary hero line ("Venituri: +X") and the net toggle;
    /// neutral rows (transfers/cash moves/loans) are excluded from every total but
    /// still appear in the list and the People view.
    private var expenseTransactions: [Transaction] { searchedTransactions.filter { $0.direction == .expense } }
    private var incomeTransactions: [Transaction] { searchedTransactions.filter { $0.direction == .income } }

    /// The list drills further than the charts: the shared category filter
    /// (`selectedRef`) and the shared bucket filter (`selectedBucket`) compose
    /// here, over the SAME `searchedTransactions` the charts aggregate — so the
    /// list can never disagree with the charts about the underlying dataset (A1).
    private var listTransactions: [Transaction] {
        var result = searchedTransactions
        if let selectedRef {
            result = result.filter { $0.categoryRef == selectedRef }
        }
        if let selectedBucket {
            let range = FinancesAnalytics.bucketRange(start: selectedBucket.start, unit: preset.bucketUnit, calendar: calendar)
            result = result.filter { $0.date >= range.start && $0.date < range.end }
        }
        return result
    }

    private var previousWindowTransactions: [Transaction] {
        let interval = previousInterval
        let inWindow = contextFiltered.filter { $0.date >= interval.start && $0.date < interval.end }
        return applySearch(inWindow)
    }

    private func spendItem(_ tx: Transaction) -> SpendItem {
        SpendItem(amount: tx.amount, currency: tx.currency, category: tx.category, customCategoryID: tx.customCategoryID, date: tx.date)
    }

    /// Analytics items (EXPENSES only, A3) with the no-rate currency toggle applied.
    private var analyticsSpendItems: [SpendItem] {
        let base = expenseTransactions
        let scoped = displayRate == nil ? base.filter { $0.currency == currencyToggle } : base
        return scoped.map(spendItem)
    }
    private var previousSpendItems: [SpendItem] {
        let base = previousWindowTransactions.filter { $0.direction == .expense }
        let scoped = displayRate == nil ? base.filter { $0.currency == currencyToggle } : base
        return scoped.map(spendItem)
    }

    /// Income items (A3) for the secondary hero line + net toggle.
    private var incomeSpendItems: [SpendItem] {
        let scoped = displayRate == nil ? incomeTransactions.filter { $0.currency == currencyToggle } : incomeTransactions
        return scoped.map(spendItem)
    }
    private var incomeTotal: Decimal { FinancesAnalytics.combinedTotal(incomeSpendItems, rate: rateDecimal) }
    private var hasIncome: Bool { !incomeTransactions.isEmpty }
    /// Net cash flow = income − spending (A3 net toggle).
    private var netTotal: Decimal { incomeTotal - periodTotal }
    private var heroMode: HeroMode { HeroMode(rawValue: heroModeRaw) ?? .spent }
    private var heroModeBinding: Binding<HeroMode> {
        Binding(get: { heroMode }, set: { heroModeRaw = $0.rawValue })
    }

    // MARK: - Aggregates

    private var periodTotal: Decimal {
        FinancesAnalytics.combinedTotal(analyticsSpendItems, rate: rateDecimal)
    }
    private var categoryTotals: [FinancesAnalytics.CategoryTotal] {
        FinancesAnalytics.byCategory(analyticsSpendItems, rate: rateDecimal)
    }
    private var buckets: [FinancesAnalytics.TimeBucket] {
        FinancesAnalytics.buckets(analyticsSpendItems, interval: currentInterval, unit: preset.bucketUnit, calendar: calendar, rate: rateDecimal)
    }
    private var averageBucket: Decimal {
        FinancesAnalytics.average(buckets)
    }
    private var currentTrend: [FinancesAnalytics.CumulativePoint] {
        FinancesAnalytics.cumulative(analyticsSpendItems, rate: rateDecimal, isPrevious: false, displayShift: 0)
    }
    private var previousTrend: [FinancesAnalytics.CumulativePoint] {
        let shift = currentInterval.start.timeIntervalSince(previousInterval.start)
        return FinancesAnalytics.cumulative(previousSpendItems, rate: rateDecimal, isPrevious: true, displayShift: shift)
    }

    // MARK: - Grouping

    private var groups: [TransactionGroup] {
        makeGroups(from: listTransactions, grouping: groupingBinding.wrappedValue)
    }

    private func makeGroups(from transactions: [Transaction], grouping: TransactionGrouping) -> [TransactionGroup] {
        switch grouping {
        case .category:
            let dict = Dictionary(grouping: transactions) { $0.categoryRef }
            // Preset categories first (enum order), then custom categories
            // (creation order), then uncategorized last.
            var orderedKeys: [CategoryRef?] = TransactionCategory.allCases.map { .preset($0) }
            orderedKeys += customCategories.map { CategoryRef.custom($0.id) }
            orderedKeys.append(nil)
            let customs = customLookup
            return orderedKeys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return TransactionGroup(
                    id: CategoryRef.sortKey(key),
                    title: categoryStyle(key, customs: customs).label,
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
                    title: monthStart.formatted(.dateTime.month(.wide).year().locale(locale)),
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
                    title: key ?? String(localized: "finances.noMerchant"),
                    transactions: items
                )
            }

        case .people:
            // People is rendered separately (paid/received/net rows) — never as
            // transaction sections.
            return []
        }
    }

    // MARK: - People (B1)

    /// Per-counterparty summaries for the People grouping, over the searched set
    /// (context + timeframe + search), currency-scoped like the analytics.
    private var peopleSummaries: [PersonSummary] {
        let items = searchedTransactions.compactMap { tx -> PersonItem? in
            guard let cp = tx.counterparty, !cp.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return PersonItem(counterparty: cp, amount: tx.amount, currency: tx.currency, direction: tx.direction, date: tx.date)
        }
        let scoped = displayRate == nil ? items.filter { $0.currency == currencyToggle } : items
        return PeopleAnalytics.summaries(scoped, rate: displayRate)
    }

    @ViewBuilder
    private var peopleSections: some View {
        if peopleSummaries.isEmpty {
            Section {
                peopleEmptyRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            Section {
                ForEach(peopleSummaries) { person in
                    NavigationLink(value: PersonRoute(name: person.counterparty)) {
                        PersonSummaryRow(person: person, currencyCode: currencyCode)
                    }
                    .listRowBackground(Palette.surface)
                }
            } header: {
                PeopleColumnHeader()
            }
        }
    }

    private var peopleEmptyRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28))
                .foregroundStyle(Palette.secondaryInk.opacity(0.6))
            Text("finances.people.empty")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("finances.peopleEmpty")
    }
}

// MARK: - Navigation destinations (push-safety seam)

/// Registers the `Transaction` + `PersonRoute` navigation destinations ONLY when
/// FinancesView roots its own `NavigationStack`. When embedded as a drill-down in
/// the Raport hub (`enabled == false`), the hub owns the single shared registration
/// for the whole stack, so re-declaring them here would duplicate it.
private struct FinancesNavigationDestinations: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationDestination(for: Transaction.self) { transaction in
                    TransactionDetailView(transaction: transaction)
                }
                .navigationDestination(for: PersonRoute.self) { route in
                    PersonDetailView(counterparty: route.name)
                }
        } else {
            content
        }
    }
}

// MARK: - Breakdown row

/// One tappable category breakdown row (D1): color dot + icon, label, total,
/// share of period, and count. Tapping filters the list to that category.
private struct CategoryBreakdownRow: View {
    @Environment(\.metrics) private var metrics
    let item: FinancesAnalytics.CategoryTotal
    let style: CategoryStyle
    let fraction: Double
    let currencyCode: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: metrics.elementSpacing) {
            Image(systemName: style.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 30, height: 30)
                .background(Palette.canvas, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(style.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Text("\(CountLabels.items(item.count)) · \(Int((fraction * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }

            Spacer(minLength: 8)

            Text(item.total, format: .number.precision(.fractionLength(0...2)))
                .font(Typography.amount(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text(currencyCode)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
        }
        .padding(.vertical, metrics.rowVInset)
        .padding(.horizontal, metrics.elementSpacing)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isSelected ? style.color.opacity(0.12) : Color.clear)
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
        case .personal: String(localized: "context.personal")
        case .work: String(localized: "context.work")
        case .all: String(localized: "finances.segment.all")
        }
    }
}

/// A3 — the hero total mode (spending vs net cash flow), `@AppStorage`-remembered.
enum HeroMode: String, CaseIterable, Identifiable, Sendable {
    case spent, net
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spent: String(localized: "finances.hero.spent")
        case .net: String(localized: "finances.hero.net")
        }
    }
}

/// Navigation value for a People-view person → their history + mini-summary (B1).
struct PersonRoute: Hashable, Sendable {
    let name: String
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
    let customCategoryID: UUID?
    let descriptionText: String
    let merchant: String?
    let date: Date
    let rawTranscript: String?
    let source: TransactionSource
    let direction: TransactionDirection
    let counterparty: String?
    let attachmentID: UUID?
    let createdAt: Date

    init(_ transaction: Transaction) {
        amount = transaction.amount
        currency = transaction.currency
        context = transaction.context
        category = transaction.category
        customCategoryID = transaction.customCategoryID
        descriptionText = transaction.descriptionText
        merchant = transaction.merchant
        date = transaction.date
        rawTranscript = transaction.rawTranscript
        source = transaction.source
        direction = transaction.direction
        counterparty = transaction.counterparty
        attachmentID = transaction.attachmentID
        createdAt = transaction.createdAt
    }
}
