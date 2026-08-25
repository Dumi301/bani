import SwiftUI
import SwiftData
import UIKit

/// The Raport hub (v2 teardown) — the app's face. The report stops being an export
/// at the end of the pipeline and becomes a living overview screen (VISION §2
/// "Raport Custom", Board 2). Top to bottom: Position (liquidity + reconcile +
/// cash flow), Owed to me (receivables), Debt — bank, Debt — investors, Projects
/// (invested + budgeting). The old Finances tab is demoted to a drill-down reached
/// from here ("All transactions"); its list / analytics / charts / search are
/// REUSED (`FinancesView`, pushed), never rewritten.
///
/// Every section renders an empty state with zero data. The two exporters
/// (`RaportCustomExporter`, `CentralizatorPivotExporter`) hang off the toolbar as
/// one-way `.xlsx` share actions. All math is the pure `RaportHubBuilder`.
struct RaportHubView: View {
    @Environment(RateService.self) private var rates
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: [SortDescriptor(\Loan.createdAt, order: .reverse)]) private var loans: [Loan]
    @Query(sort: [SortDescriptor(\Project.sortOrder), SortDescriptor(\Project.createdAt, order: .reverse)])
    private var projects: [Project]
    @Query private var scheduledItems: [ScheduledItem]
    @Query private var customCategories: [CustomCategory]
    /// P11 — the People registry (P6) feeds smart-search person verification.
    @Query private var people: [Person]
    /// P11 — learned keyword rules feed the free-text leg of smart search, the
    /// same way `FinancesView.learnedSnapshots` feeds the existing keyword search.
    @Query private var categoryRules: [CategoryRule]

    @AppStorage("raportHorizon") private var horizonRaw: Int = LiquidityHorizon.days30.rawValue
    @AppStorage("raportCashflow") private var cashflowRaw: String = TimeframePreset.month.rawValue

    @State private var shareItem: ShareItem?

    // MARK: - P11 smart search state

    /// The live query text bound to `.searchable`.
    @State private var smartSearchText: String = ""
    /// The compiled structured filter, or `nil` — either "not searched yet" (see
    /// `hasSearched`) or the fallback marker (FM unavailable / nothing usable),
    /// in which case results come from the raw keyword search instead.
    @State private var smartSearchFilter: SearchFilter?
    /// Whether a search has actually run for the current `smartSearchText` —
    /// distinguishes "idle" (hub renders exactly as P7 shipped it) from "FM
    /// compiled an empty/fallback filter" (both `smartSearchFilter == nil`).
    @State private var hasSearched = false

    private var calendar: Calendar { .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: metrics.sectionSpacing) {
                    if hasSearched { smartSearchSection }
                    let model = self.model
                    positionSection(model.position)
                    owedSection(model.receivables)
                    debtSection(model.bankDebt, title: "raport.section.debtBank",
                                emptyKey: "raport.empty.debtBank", showCostOfCapital: false)
                    debtSection(model.investorDebt, title: "raport.section.debtInvestors",
                                emptyKey: "raport.empty.debtInvestors", showCostOfCapital: true)
                    projectsSection(model.projects)
                    allTransactionsRow
                }
                .padding(.horizontal, metrics.screenPadding)
                .padding(.vertical, metrics.elementSpacing)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("raport.title")
            .accessibilityIdentifier("raport.hub.root")
            // ONE Transaction / PersonRoute destination for the whole hub stack —
            // shared by the pushed FinancesView (embedded, its own registration off)
            // and ProjectDetailView, so there is no duplicate registration.
            .navigationDestination(for: Transaction.self) { TransactionDetailView(transaction: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonDetailView(counterparty: $0.name) }
            .toolbar { exportToolbar }
            .sheet(item: $shareItem) { item in
                ActivityView(url: item.url)
            }
            // P11 — natural-language search over the whole history (VISION §1
            // "search engine (smart)"). A deliberate submit (not live-as-you-type,
            // since compiling races an async FM pass) triggers `runSmartSearch`.
            .searchable(text: $smartSearchText, prompt: Text("raport.search.prompt"))
            .onSubmit(of: .search) { Task { await runSmartSearch() } }
            .onChange(of: smartSearchText) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasSearched = false
                    smartSearchFilter = nil
                }
            }
        }
    }

    // MARK: - Model

    private var model: RaportHubModel {
        RaportHubBuilder.build(
            lines: transactions.map {
                RaportTxLine(amount: $0.amount, currency: $0.currency, direction: $0.direction,
                             projectID: $0.projectID, loanID: $0.loanID, date: $0.date)
            },
            loans: loans.map(\.snapshot),
            projects: projects.map(\.snapshot),
            items: scheduledItems.map(\.snapshot),
            rate: rates.rate,
            horizon: horizon,
            cashflowInterval: cashflowInterval,
            loanItemIDs: Set(scheduledItems.filter { $0.loanID != nil }.map(\.id)),
            now: Date(),
            calendar: calendar
        )
    }

    private var horizon: LiquidityHorizon { LiquidityHorizon(rawValue: horizonRaw) ?? .days30 }
    private var horizonBinding: Binding<LiquidityHorizon> {
        Binding(get: { horizon }, set: { horizonRaw = $0.rawValue })
    }
    private var cashflowPreset: TimeframePreset { TimeframePreset(rawValue: cashflowRaw) ?? .month }
    private var cashflowInterval: DateInterval {
        TimeframeRange.current(cashflowPreset, reference: Date(), calendar: calendar, custom: nil)
    }

    // MARK: - P11 smart search (VISION §1 "search engine (smart)")

    /// Learned rules feed the free-text leg of smart search (mirrors
    /// `FinancesView.learnedSnapshots`).
    private var learnedSnapshots: [CategoryRuleSnapshot] {
        categoryRules
            .filter { $0.origin == .learned }
            .map { CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, customCategoryID: $0.customCategoryID, origin: $0.origin, hitCount: $0.hitCount) }
    }

    private var smartSearchItems: [SmartSearchService.Item] { transactions.map(SmartSearchService.Item.init) }

    /// id → snapshot lookup for resolving custom categories in the search
    /// results/chips (mirrors `FinancesView.customLookup`).
    private var customLookup: CustomCategoryLookup { customCategories.lookup }

    /// Compiles + executes `smartSearchText` (FM compiles, deterministic code
    /// verifies + executes it — P11). FM unavailable/nothing usable ⇒
    /// `smartSearchFilter` stays `nil` and `smartSearchResults` falls back to the
    /// raw keyword search, byte-identical to today.
    private func runSmartSearch() async {
        let outcome = await SmartSearchService.search(
            query: smartSearchText, now: Date(), calendar: calendar, items: smartSearchItems,
            projects: projects.map(\.snapshot), people: people.map(\.snapshot),
            historicalCounterparties: PersonStore.historicalCounterparties(transactions: transactions, scheduledItems: scheduledItems),
            customCategories: customCategories.map(\.snapshot), learnedRules: learnedSnapshots,
            compiler: FoundationModelsQueryCompiler()
        )
        smartSearchFilter = outcome.filter
        hasSearched = true
    }

    /// Results as live `Transaction`s (for `TransactionRow` + the shared
    /// `Transaction` navigation destination). Re-executed synchronously off
    /// `smartSearchFilter` on every render — pure + cheap — so clearing a chip
    /// (which mutates one field of the filter) re-filters immediately with no
    /// second FM round-trip.
    private var smartSearchResults: [Transaction] {
        let raw: [SmartSearchService.Item]
        if let smartSearchFilter {
            raw = SmartSearchService.execute(smartSearchFilter, items: smartSearchItems, learnedRules: learnedSnapshots, customCategories: customCategories.map(\.snapshot))
        } else {
            raw = SmartSearchService.keywordFallback(smartSearchText, items: smartSearchItems, customCategories: customCategories.map(\.snapshot), learnedRules: learnedSnapshots)
        }
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        return raw.compactMap { byID[$0.id] }
    }

    @ViewBuilder
    private var smartSearchSection: some View {
        let results = smartSearchResults
        sectionCard(title: "raport.search.resultsTitle") {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                if !understoodAsChips.isEmpty {
                    understoodAsChipRow
                }
                if results.isEmpty {
                    emptyRow("raport.search.empty", systemImage: "magnifyingglass", id: "raport.search.empty")
                } else {
                    ForEach(results, id: \.id) { transaction in
                        NavigationLink(value: transaction) {
                            TransactionRow(transaction: transaction, customs: customLookup)
                        }
                        .buttonStyle(.plain)
                        if transaction.id != results.last?.id {
                            Divider().background(Palette.hairline)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("raport.search.section")
    }

    /// One dismissible chip per compiled filter field — the "understood as"
    /// trust surface. Tapping ✕ clears ONLY that field and re-filters (no
    /// second FM round-trip, see `smartSearchResults`).
    private var understoodAsChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: metrics.elementSpacing) {
                ForEach(understoodAsChips) { chip in
                    filterChip(label: chip.label, systemImage: chip.systemImage, color: Palette.accent, clear: chip.clear)
                        .accessibilityIdentifier("raport.search.chip.\(chip.id)")
                }
            }
        }
    }

    private struct SearchChip: Identifiable {
        let id: String
        let label: String
        let systemImage: String
        let clear: () -> Void
    }

    private var understoodAsChips: [SearchChip] {
        guard let filter = smartSearchFilter else { return [] }
        var chips: [SearchChip] = []
        if let range = filter.dateRange {
            chips.append(SearchChip(id: "date", label: dateRangeLabel(range), systemImage: "calendar") {
                smartSearchFilter?.dateRange = nil
            })
        }
        if !filter.projectIDs.isEmpty {
            let names = filter.projectIDs.compactMap { id in projects.first { $0.id == id }?.name }
            if !names.isEmpty {
                chips.append(SearchChip(id: "project", label: names.joined(separator: ", "), systemImage: "folder") {
                    smartSearchFilter?.projectIDs = []
                })
            }
        }
        if !filter.personNames.isEmpty {
            chips.append(SearchChip(id: "person", label: filter.personNames.joined(separator: ", "), systemImage: "person.fill") {
                smartSearchFilter?.personNames = []
            })
        }
        if !filter.categoryRefs.isEmpty {
            let labels = filter.categoryRefs.map { categoryStyle($0, customs: customLookup).label }
            chips.append(SearchChip(id: "category", label: labels.joined(separator: ", "), systemImage: "tag") {
                smartSearchFilter?.categoryRefs = []
            })
        }
        if filter.amountMin != nil || filter.amountMax != nil {
            chips.append(SearchChip(id: "amount", label: amountRangeLabel(filter), systemImage: "banknote") {
                smartSearchFilter?.amountMin = nil
                smartSearchFilter?.amountMax = nil
            })
        }
        if let direction = filter.direction {
            chips.append(SearchChip(id: "direction", label: direction.label, systemImage: direction.systemImage) {
                smartSearchFilter?.direction = nil
            })
        }
        if let currency = filter.currency {
            chips.append(SearchChip(id: "currency", label: currency.displayCode, systemImage: "coloncurrencysign.circle") {
                smartSearchFilter?.currency = nil
            })
        }
        return chips
    }

    private func dateRangeLabel(_ range: DateInterval) -> String {
        let start = range.start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        // The stored end is exclusive; show the inclusive last day.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
        let end = lastDay.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        return "\(start) – \(end)"
    }

    private func amountRangeLabel(_ filter: SearchFilter) -> String {
        switch (filter.amountMin, filter.amountMax) {
        case let (min?, max?):
            return "\(min.formatted(.number.precision(.fractionLength(0...0)))) – \(max.formatted(.number.precision(.fractionLength(0...0))))"
        case let (min?, nil):
            return "≥ \(min.formatted(.number.precision(.fractionLength(0...0))))"
        case let (nil, max?):
            return "≤ \(max.formatted(.number.precision(.fractionLength(0...0))))"
        default:
            return ""
        }
    }

    /// A dismissible chip (mirrors `FinancesView`'s filter chip): a brushed-metal
    /// chip whose accent-colored border + text signal one live filter field; the
    /// ✕ clears it.
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

    // MARK: - Position

    @ViewBuilder
    private func positionSection(_ position: RaportPosition) -> some View {
        VStack(spacing: metrics.elementSpacing) {
            // Reuse the P4 portfolio header verbatim — it carries the 30/60/90
            // horizon chips AND the reconcile entry point (kept alive here).
            PortfolioHeaderView(
                netLoggedPosition: position.netLoggedPosition,
                liquidity: position.liquidity,
                horizon: horizonBinding,
                bnrDate: rates.bnrPublishingDate,
                rate: rates.rate
            )
            cashflowCard(position)
        }
    }

    private func cashflowCard(_ position: RaportPosition) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack {
                Text("raport.cashflow.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)
                Spacer()
                Picker("raport.cashflow.title", selection: cashflowBinding) {
                    ForEach([TimeframePreset.week, .month, .sixMonths, .year]) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .tint(Palette.accent)
                .accessibilityIdentifier("raport.cashflowPicker")
            }
            HStack(spacing: metrics.sectionSpacing) {
                cashStat(labelKey: "raport.cashflow.in", value: position.cashIn, sign: "+")
                cashStat(labelKey: "raport.cashflow.out", value: position.cashOut, sign: "−")
                cashStat(labelKey: "raport.cashflow.net", value: position.cashNet, sign: position.cashNet < 0 ? "−" : "+")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("raport.cashflow")
    }

    private func cashStat(labelKey: LocalizedStringKey, value: Decimal, sign: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(labelKey)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.secondaryInk)
            Text("\(sign)\(value.magnitude.formatted(.number.precision(.fractionLength(0...0)))) \(Currency.ron.displayCode)")
                .font(Typography.amount(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cashflowBinding: Binding<TimeframePreset> {
        Binding(get: { cashflowPreset }, set: { cashflowRaw = $0.rawValue })
    }

    // MARK: - Owed to me (receivables)

    @ViewBuilder
    private func owedSection(_ summary: ReceivablesSummary) -> some View {
        sectionCard(title: "raport.section.owed") {
            if summary.people.isEmpty {
                emptyRow("raport.empty.owed", systemImage: "person.2.slash", id: "raport.owed.empty")
            } else {
                NavigationLink { ReceivablesView() } label: {
                    VStack(spacing: metrics.rowSpacing) {
                        HStack {
                            Text("receivables.grandTotal.label")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Palette.secondaryInk)
                            Spacer()
                            Text("\(summary.grandTotal.formatted(.number.precision(.fractionLength(0...2)))) \(Currency.ron.displayCode)")
                                .font(Typography.amount(.subheadline, weight: .bold))
                                .foregroundStyle(Palette.accent)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.secondaryInk)
                        }
                        ForEach(summary.people.prefix(3)) { person in
                            HStack {
                                Text(person.counterparty)
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(person.total.formatted(.number.precision(.fractionLength(0...0)))) \(Currency.ron.displayCode)")
                                    .font(Typography.mono(.caption))
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("raport.owed.link")
            }
        }
    }

    // MARK: - Debt (bank / investor)

    @ViewBuilder
    private func debtSection(_ section: RaportDebtSection, title: LocalizedStringKey,
                             emptyKey: LocalizedStringKey, showCostOfCapital: Bool) -> some View {
        sectionCard(title: title) {
            if section.isEmpty {
                emptyRow(emptyKey, systemImage: "banknote", id: "raport.debt.empty")
            } else {
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(section.rows) { row in
                        if let loan = loans.first(where: { $0.id == row.loanID }) {
                            NavigationLink { LoanDetailView(loan: loan) } label: {
                                debtRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if showCostOfCapital {
                        Divider().background(Palette.hairline)
                        HStack {
                            Text("raport.costOfCapital")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            Text("\(section.costOfCapital.formatted(.number.precision(.fractionLength(0...2)))) \(Currency.ron.displayCode)")
                                .font(Typography.amount(.subheadline, weight: .bold))
                                .foregroundStyle(Palette.accent)
                        }
                        .accessibilityIdentifier("raport.costOfCapital")
                        Text("raport.debt.costOfCapitalNote")
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func debtRow(_ row: RaportDebtRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(row.outstanding.formatted(.number.precision(.fractionLength(0...2)))) \(row.currency.displayCode)")
                    .font(Typography.amount(.subheadline, weight: .bold))
                    .foregroundStyle(Palette.accent)
            }
            ProgressView(value: progressValue(row))
                .tint(Palette.accent)
            HStack {
                Text("loan.card.percentLeft \(percentText(row.percentLeft))")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
                Spacer()
                if let payment = row.nextPayment, let due = row.nextDueDate {
                    Text("\(payment.formatted(.number.precision(.fractionLength(0...0)))) · \(due.formatted(.dateTime.day().month(.abbreviated).locale(locale)))")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            if let interest = row.nextInterest, let principal = row.nextPrincipal {
                Text("\(String(localized: "raport.debt.interest")) \(interest.formatted(.number.precision(.fractionLength(0...0)))) · \(String(localized: "raport.debt.principal")) \(principal.formatted(.number.precision(.fractionLength(0...0))))")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }
            if let projectName = row.bookedToProjectName {
                Text("raport.debt.bookedTo \(projectName)")
                    .font(.caption2)
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("raport.debt.row")
    }

    /// Progress = fraction of principal repaid (0…1).
    private func progressValue(_ row: RaportDebtRow) -> Double {
        let repaid = (100 - NSDecimalNumber(decimal: row.percentLeft).doubleValue) / 100
        return min(1, max(0, repaid))
    }
    private func percentText(_ pct: Decimal) -> String {
        "\(pct.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    // MARK: - Projects

    @ViewBuilder
    private func projectsSection(_ rows: [RaportProjectRow]) -> some View {
        sectionCard(title: "raport.section.projects") {
            if rows.isEmpty {
                emptyRow("raport.empty.projects", systemImage: "folder", id: "raport.projects.empty")
            } else {
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(rows) { row in
                        if let project = projects.first(where: { $0.id == row.projectID }) {
                            NavigationLink { ProjectDetailView(project: project) } label: {
                                projectRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func projectRow(_ row: RaportProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(CustomCategoryPalette.color(row.colorIndex)).frame(width: 9, height: 9)
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                statPair(labelKey: "raport.projects.invested", value: row.invested)
            }
            if row.hasBudget {
                ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: row.percentPaid).doubleValue / 100)))
                    .tint(Palette.accent)
                HStack {
                    Text("\(String(localized: "raport.projects.paid")) \(row.paid.formatted(.number.precision(.fractionLength(0...0)))) · \(String(localized: "raport.projects.due")) \(row.due.formatted(.number.precision(.fractionLength(0...0)))) · \(percentText(row.percentPaid))")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryInk)
                    Spacer(minLength: 6)
                    if let next = row.nextDueDate {
                        Text("raport.projects.nextDue \(next.formatted(.dateTime.day().month(.abbreviated).locale(locale)))")
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("raport.project.row")
    }

    private func statPair(labelKey: LocalizedStringKey, value: Decimal) -> some View {
        HStack(spacing: 4) {
            Text(labelKey).font(.caption2).foregroundStyle(Palette.secondaryInk)
            Text("\(value.formatted(.number.precision(.fractionLength(0...0)))) \(Currency.ron.displayCode)")
                .font(Typography.amount(.caption, weight: .semibold))
                .foregroundStyle(Palette.accent)
        }
    }

    // MARK: - Drill-downs

    private var allTransactionsRow: some View {
        NavigationLink {
            // REUSE the whole Finances surface (list + analytics + charts + search),
            // embedded (no own NavigationStack — it uses this hub's stack).
            FinancesView(embedInNavigationStack: false)
        } label: {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Palette.accent)
                Text("raport.allTransactions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.secondaryInk)
            }
            .padding(metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .metalSurface(cornerRadius: Radius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("raport.allTransactions")
    }

    // MARK: - Shared section chrome

    @ViewBuilder
    private func sectionCard<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
    }

    private func emptyRow(_ key: LocalizedStringKey, systemImage: String, id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk.opacity(0.7))
            Text(key)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, metrics.rowVInset)
        .accessibilityIdentifier(id)
    }

    // MARK: - Export

    @ToolbarContentBuilder
    private var exportToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    shareItem = writeExport(RaportCustomExporter.xlsx(raportExportContent()),
                                            name: "Raport.xlsx")
                } label: {
                    Label("raport.export.raport", systemImage: "doc.text")
                }
                Button {
                    shareItem = writeExport(CentralizatorPivotExporter.xlsx(centralizatorRows()),
                                            name: "Centralizator.xlsx")
                } label: {
                    Label("raport.export.centralizator", systemImage: "tablecells")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityIdentifier("raport.exportMenu")
            .accessibilityLabel(Text("raport.export.menu"))
        }
    }

    /// Assemble the Raport export content (RON) from the live hub model.
    private func raportExportContent() -> RaportCustomExporter.Content {
        let m = model
        var sections: [RaportCustomExporter.Section] = []
        sections.append(.init(title: String(localized: "raport.section.position"), lines: [
            .init(label: String(localized: "portfolio.netPosition"), value: m.position.netLoggedPosition),
            .init(label: String(localized: "portfolio.freeLiquidity"), value: m.position.liquidity.freeLiquidity),
            .init(label: String(localized: "raport.cashflow.in"), value: m.position.cashIn),
            .init(label: String(localized: "raport.cashflow.out"), value: m.position.cashOut),
            .init(label: String(localized: "receivables.grandTotal.label"), value: m.receivables.grandTotal),
        ]))
        if !m.bankDebt.isEmpty {
            sections.append(.init(title: String(localized: "raport.section.debtBank"),
                                  lines: m.bankDebt.rows.map { .init(label: $0.name, value: $0.outstanding) }))
        }
        if !m.investorDebt.isEmpty {
            var lines = m.investorDebt.rows.map { RaportCustomExporter.Line(label: $0.name, value: $0.outstanding) }
            lines.append(.init(label: String(localized: "raport.costOfCapital"), value: m.investorDebt.costOfCapital))
            sections.append(.init(title: String(localized: "raport.section.debtInvestors"), lines: lines))
        }
        if !m.projects.isEmpty {
            sections.append(.init(title: String(localized: "raport.section.projects"),
                                  lines: m.projects.map { .init(label: $0.name, value: $0.invested) }))
        }
        return RaportCustomExporter.Content(sections: sections)
    }

    /// Resolve every non-neutral transaction into a categorised pivot row (RON).
    private func centralizatorRows() -> [CentralizatorPivotExporter.Row] {
        let customLookup = Dictionary(uniqueKeysWithValues: customCategories.map { ($0.id, $0.name) })
        let rate = rates.rate.map { Decimal($0) }
        return transactions.compactMap { tx in
            guard tx.direction != .neutral else { return nil }
            let ron: Decimal
            switch tx.currency {
            case .ron: ron = tx.amount
            case .eur: ron = rate.map { tx.amount * $0 } ?? tx.amount
            }
            return CentralizatorPivotExporter.Row(
                category: categoryName(tx, customLookup: customLookup),
                amount: ron,
                isCredit: tx.direction == .income
            )
        }
    }

    private func categoryName(_ tx: Transaction, customLookup: [UUID: String]) -> String {
        guard let ref = tx.categoryRef else { return String(localized: "category.uncategorized") }
        switch ref {
        case .preset(let category): return category.label
        case .custom(let id): return customLookup[id] ?? String(localized: "category.uncategorized")
        }
    }

    /// Write export bytes to a temp `.xlsx` and wrap the URL for the share sheet.
    private func writeExport(_ data: Data, name: String) -> ShareItem? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return ShareItem(url: url)
        } catch {
            return nil
        }
    }
}

// MARK: - Share sheet plumbing

/// Identifiable wrapper so `.sheet(item:)` can present a produced export file.
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal `UIActivityViewController` bridge for sharing an exported file.
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
