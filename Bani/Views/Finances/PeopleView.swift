import SwiftUI
import SwiftData

/// Column header for the People list (B1): Paid / Received / Net.
struct PeopleColumnHeader: View {
    var body: some View {
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

    let counterparty: String

    private var transactions: [Transaction] {
        let key = Categorizer.normalize(counterparty)
        return allTransactions.filter { Categorizer.normalize($0.counterparty ?? "") == key }
    }

    private var summary: PersonSummary? {
        let items = transactions.map { PersonItem(counterparty: counterparty, amount: $0.amount, currency: $0.currency, direction: $0.direction, date: $0.date) }
        return PeopleAnalytics.summaries(items, rate: rates.rate).first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                if let summary { miniSummary(summary) }
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
