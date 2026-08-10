import SwiftUI

/// A single row in the Finances list: category icon, description, merchant,
/// context tag, and the amount. The amount uses the deep-green accent per the
/// design system's "positive amounts" rule (`## DESIGN SYSTEM & THEME`).
struct TransactionRow: View {
    @Environment(\.metrics) private var metrics
    let transaction: Transaction
    /// Lookup for resolving a custom category's symbol/color (C3); empty → presets
    /// and uncategorized only.
    var customs: CustomCategoryLookup = [:]

    var body: some View {
        HStack(spacing: metrics.elementSpacing) {
            categoryIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.descriptionText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let party = transaction.counterparty, !party.isEmpty {
                        Text(party)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryInk)
                            .lineLimit(1)
                    } else if let merchant = transaction.merchant, !merchant.isEmpty {
                        Text(merchant)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryInk)
                            .lineLimit(1)
                    }
                    contextTag
                    if transaction.source == .autoLogged { autoBadge }
                    Text(dateText)
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(1)
                        .accessibilityIdentifier("transactionRow.date")
                }
            }

            Spacer(minLength: 8)

            amountText
        }
        .padding(.vertical, metrics.rowVInset)
    }

    /// C3: today's entries show just the time; older entries show a compact
    /// date+time. Locale-aware `FormatStyle`, so an RO device reads RO order.
    private var dateText: String {
        if Calendar.current.isDateInToday(transaction.date) {
            return transaction.date.formatted(date: .omitted, time: .shortened)
        }
        return transaction.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var categoryIcon: some View {
        let ref = transaction.categoryRef
        let style = categoryStyle(ref, customs: customs)
        return Image(systemName: ref == nil ? "circle.dashed" : style.systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ref == nil ? Palette.secondaryInk : style.color)
            .frame(width: 32, height: 32)
            .background(Palette.canvas, in: Circle())
    }

    private var contextTag: some View {
        Text(transaction.context.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(transaction.context.tagColorName))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(transaction.context.tagColorName).opacity(0.15), in: Capsule())
    }

    /// Provenance badge for an auto-logged payment (Apple Pay / share-sheet
    /// capture) — a distinct "auto" chip so these rows are never invisible.
    private var autoBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text("autolog.badge")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Palette.accent.opacity(0.14), in: Capsule())
        .accessibilityIdentifier("transactionRow.autoBadge")
    }

    /// Amount + currency code, monospaced. A3 direction styling: income shows a
    /// "+" prefix in the accent; neutral rows are muted; expenses keep the accent.
    private var amountText: Text {
        Text(transaction.direction.amountPrefix)
            .font(Typography.amount(.title3, weight: .bold))
            .foregroundStyle(amountColor)
        + Text(transaction.amount, format: .number.precision(.fractionLength(0...2)))
            .font(Typography.amount(.title3, weight: .bold))
            .foregroundStyle(amountColor)
        + Text(" \(transaction.currency.displayCode)")
            .font(.system(.caption).weight(.semibold))
            .foregroundStyle(Palette.secondaryInk)
    }

    private var amountColor: Color {
        switch transaction.direction {
        case .expense, .income: Palette.accent
        case .neutral: Palette.secondaryInk
        }
    }
}

#Preview {
    List {
        TransactionRow(transaction: Transaction(
            amount: 52, currency: .ron, context: .personal, category: .fuel,
            descriptionText: "benzină", merchant: "OMV", source: .voice
        ))
        TransactionRow(transaction: Transaction(
            amount: 120, currency: .eur, context: .work, category: nil,
            descriptionText: "taxi aeroport", merchant: nil, source: .manual
        ))
    }
}
