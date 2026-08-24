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

    @AppStorage("raportHorizon") private var horizonRaw: Int = LiquidityHorizon.days30.rawValue
    @AppStorage("raportCashflow") private var cashflowRaw: String = TimeframePreset.month.rawValue

    @State private var shareItem: ShareItem?

    private var calendar: Calendar { .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: metrics.sectionSpacing) {
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
