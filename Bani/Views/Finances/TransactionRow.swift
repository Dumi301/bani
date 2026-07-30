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
                    if let merchant = transaction.merchant, !merchant.isEmpty {
                        Text(merchant)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryInk)
                            .lineLimit(1)
                    }
                    contextTag
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

    /// Amount + currency code, monospaced, accent-colored (money → accent).
    private var amountText: Text {
        Text(transaction.amount, format: .number.precision(.fractionLength(0...2)))
            .font(Typography.amount(.title3, weight: .bold))
            .foregroundStyle(Palette.accent)
        + Text(" \(transaction.currency.displayCode)")
            .font(.system(.caption).weight(.semibold))
            .foregroundStyle(Palette.secondaryInk)
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
