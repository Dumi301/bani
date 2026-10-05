import SwiftUI
import SwiftData

/// Column header for the People list (B1): Paid / Received / Net. Also the
/// entry point into the v1.3 receivables surface ("who owes ME") — a self-
/// contained `NavigationLink` row (needs no ancestor `.navigationDestination`,
/// so it stays reachable without any change to `FinancesView`, which embeds
/// this header as the People section's `header:`).
struct PeopleColumnHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReceivablesEntryRow()
            columnLabels
        }
    }

    private var columnLabels: some View {
        HStack(spacing: 8) {
            Text("people.person")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("people.paid").frame(width: 74, alignment: .trailing)
            Text("people.received").frame(width: 74, alignment: .trailing)
            Text("people.net").frame(width: 74, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Palette.secondaryInk)
        .textCase(nil)
    }
}

/// Compact "who owes me" teaser + entry point (v1.3), rendered above the
/// column labels. Pushes `ReceivablesView`; the grand total is the same
/// `ReceivablesRollup` aggregation that view renders in full.
private struct ReceivablesEntryRow: View {
    @Environment(RateService.self) private var rates
    @Query private var scheduledItems: [ScheduledItem]

    private var summary: ReceivablesSummary {
        ReceivablesRollup.build(scheduledItems.map(\.snapshot), rate: rates.rateDecimal)
    }

    var body: some View {
        NavigationLink {
            ReceivablesView()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.clock")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
                Text("receivables.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 6)
                Text("\(summary.grandTotal.formatted(.number.precision(.fractionLength(0...0)))) RON")
                    .font(Typography.mono(.caption).weight(.semibold))
                    .foregroundStyle(Palette.accent)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("receivables.entryRow")
    }
}

/// One counterparty row: name + paid / received / net columns (B1).
struct PersonSummaryRow: View {
    @Environment(\.metrics) private var metrics
    let person: PersonSummary
    let currencyCode: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.counterparty)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(CountLabels.items(person.count))
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            amount(person.paid, color: Palette.ink)
            amount(person.received, color: Palette.accent)
            amount(person.net, color: person.net < 0 ? Palette.secondaryInk : Palette.accent, signed: true)
        }
        .padding(.vertical, metrics.rowVInset)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("people.row")
    }

    private func amount(_ value: Decimal, color: Color, signed: Bool = false) -> some View {
        let prefix = signed && value > 0 ? "+" : ""
        return Text("\(prefix)\(value.formatted(.number.precision(.fractionLength(0...0))))")
            .font(Typography.mono(.caption))
            .foregroundStyle(color)
            .frame(width: 74, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// A person's history + mini-summary (B1): totals, a running balance when
/// loans/neutral rows exist, then their transactions newest-first.
struct PersonDetailView: View {
    @Environment(RateService.self) private var rates
    @Environment(\.metrics) private var metrics
    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @Query private var customCategories: [CustomCategory]
    // v0.4 — the worker ledger: per project, per month, and the registered
    // person's trade (editable here so "electricianul" finds them in search).
    @Query private var projects: [Project]
    @Query private var people: [Person]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @State private var roleText: String = ""

    let counterparty: String

    private var transactions: [Transaction] {
        let key = Categorizer.normalize(counterparty)
        return allTransactions.filter { Categorizer.normalize($0.counterparty ?? "") == key }
    }

    private var registered: Person? {
        let key = Categorizer.normalize(counterparty)
        return people.first { $0.normalizedName == key }
    }

    /// Paid-out RON per project (expenses only), largest first.
    private var paidByProject: [(name: String, value: Decimal)] {
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        var sums: [String: Decimal] = [:]
        for tx in transactions where tx.direction == .expense {
            let name = tx.projectID.flatMap { names[$0] } ?? String(localized: "people.noProject")
            sums[name, default: 0] += LiquidityCalculator.ronValue(of: tx.amount, currency: tx.currency, rate: rates.rateDecimal) ?? 0
        }
        return sums.map { (name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
    }

    /// Paid-out RON per month, newest first (last 12 months with activity).
    private var paidByMonth: [(month: Date, value: Decimal)] {
        let calendar = Calendar.current
        var sums: [Date: Decimal] = [:]
        for tx in transactions where tx.direction == .expense {
            guard let start = calendar.dateInterval(of: .month, for: tx.date)?.start else { continue }
            sums[start, default: 0] += LiquidityCalculator.ronValue(of: tx.amount, currency: tx.currency, rate: rates.rateDecimal) ?? 0
        }
        return sums.map { (month: $0.key, value: $0.value) }.sorted { $0.month > $1.month }.prefix(12).map { $0 }
    }

    private var summary: PersonSummary? {
        let items = transactions.map { PersonItem(counterparty: counterparty, amount: $0.amount, currency: $0.currency, direction: $0.direction, date: $0.date) }
        return PeopleAnalytics.summaries(items, rate: rates.rateDecimal).first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                if let summary { miniSummary(summary) }
                if registered != nil { roleCard }
                if paidByProject.count > 1 || paidByProject.first?.name != String(localized: "people.noProject") {
                    ledgerCard(titleKey: "people.byProject", rows: paidByProject.map { ($0.name, $0.value) })
                }
                if !paidByMonth.isEmpty {
                    ledgerCard(titleKey: "people.byMonth", rows: paidByMonth.map {
                        ($0.month.formatted(.dateTime.month(.abbreviated).year().locale(locale)), $0.value)
                    })
                }
                ForEach(transactions, id: \.id) { tx in
                    NavigationLink(value: tx) {
                        TransactionRow(transaction: tx, customs: customCategories.lookup)
                            .padding(.horizontal, metrics.cardPadding)
                            .padding(.vertical, 4)
                            .metalSurface(cornerRadius: Radius.card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(metrics.screenPadding)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle(counterparty)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { roleText = registered?.roleRaw ?? "" }
    }

    private var roleCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill").foregroundStyle(Palette.accent)
            TextField("people.role.placeholder", text: $roleText)
                .textInputAutocapitalization(.never)
                .onSubmit { saveRole() }
                .accessibilityIdentifier("people.roleField")
        }
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
    }

    private func saveRole() {
        guard let person = registered else { return }
        let clean = roleText.trimmingCharacters(in: .whitespacesAndNewlines)
        person.roleRaw = clean.isEmpty ? nil : clean
        try? modelContext.save()
    }

    private func ledgerCard(titleKey: LocalizedStringKey, rows: [(String, Decimal)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
            ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                let row = pair.element
                HStack {
                    Text(row.0).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(row.1.formatted(.number.precision(.fractionLength(0...0)))) \(Currency.ron.displayCode)")
                        .font(Typography.amount(.subheadline, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
    }

    private func miniSummary(_ s: PersonSummary) -> some View {
        VStack(spacing: metrics.elementSpacing) {
            HStack {
                stat("people.paid", s.paid, Palette.ink)
                Divider().frame(height: 36)
                stat("people.received", s.received, Palette.accent)
                Divider().frame(height: 36)
                stat("people.net", s.net, s.net < 0 ? Palette.secondaryInk : Palette.accent, signed: true)
            }
            if s.hasNeutral {
                Text("people.loansNote \(s.neutralTotal.formatted(.number.precision(.fractionLength(0...0)))) \(CountLabels.items(s.neutralCount))")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
                    .accessibilityIdentifier("people.loansNote")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .accessibilityIdentifier("people.miniSummary")
    }

    private func stat(_ titleKey: LocalizedStringKey, _ value: Decimal, _ color: Color, signed: Bool = false) -> some View {
        let prefix = signed && value > 0 ? "+" : ""
        return VStack(spacing: 4) {
            Text("\(prefix)\(value.formatted(.number.precision(.fractionLength(0...2))))")
                .font(Typography.amount(.title3, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(titleKey)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
        }
        .frame(maxWidth: .infinity)
    }
}

/// v1.3 "People registry" — "who owes ME" (VISION §2 Position): every pending
/// `ScheduledItem` with direction incoming, grouped by counterparty. Pure
/// aggregation lives in `ReceivablesRollup` (pure, testable) so P7's Raport
/// line can reuse it unchanged — this view is just its render. Reached from
/// `PeopleColumnHeader`'s `ReceivablesEntryRow`.
struct ReceivablesView: View {
    @Environment(RateService.self) private var rates
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale
    @Query private var scheduledItems: [ScheduledItem]

    private var summary: ReceivablesSummary {
        ReceivablesRollup.build(scheduledItems.map(\.snapshot), rate: rates.rateDecimal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                grandTotalHeader
                if summary.people.isEmpty {
                    emptyState
                } else {
                    ForEach(summary.people) { person in
                        personSection(person)
                    }
                }
            }
            .padding(metrics.screenPadding)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("receivables.title")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("receivables.view")
    }

    private var grandTotalHeader: some View {
        VStack(spacing: 4) {
            Text("receivables.grandTotal.label")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
            Text("\(summary.grandTotal.formatted(.number.precision(.fractionLength(0...2)))) RON")
                .font(Typography.amount(.title2, weight: .bold))
                .foregroundStyle(Palette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .accessibilityIdentifier("receivables.grandTotal")
    }

    private func personSection(_ person: PersonReceivables) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack {
                Text(person.counterparty)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 6)
                Text("\(person.total.formatted(.number.precision(.fractionLength(0...2)))) RON")
                    .font(Typography.amount(.subheadline, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            ForEach(person.items, id: \.id) { item in
                receivableRow(item)
            }
        }
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("receivables.personSection")
    }

    private func receivableRow(_ item: ScheduledItemSnapshot) -> some View {
        let overdue = item.isOverdue()
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Text(dueText(item, overdue: overdue))
                    .font(.caption2)
                    .foregroundStyle(overdue ? Color("BaniTagWork") : Palette.secondaryInk)
            }
            Spacer(minLength: 6)
            Text("\(item.amount.formatted(.number.precision(.fractionLength(0...2)))) \(item.currency.displayCode)")
                .font(Typography.mono(.caption))
                .foregroundStyle(Palette.ink)
        }
        .accessibilityIdentifier("receivables.itemRow")
    }

    private func dueText(_ item: ScheduledItemSnapshot, overdue: Bool) -> String {
        let day = item.dueDate.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        return overdue ? String(localized: "scheduled.overdue \(day)") : String(localized: "scheduled.due \(day)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 32))
                .foregroundStyle(Palette.secondaryInk)
            Text("receivables.empty")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("receivables.emptyState")
    }
}
