import SwiftUI

/// A single row in the Finances list: category icon, description, merchant,
/// context tag, and the amount. The amount uses the deep-green accent per the
/// design system's "positive amounts" rule (`## DESIGN SYSTEM & THEME`).
struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            categoryIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.descriptionText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color("BaniInk"))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let merchant = transaction.merchant, !merchant.isEmpty {
                        Text(merchant)
                            .font(.caption)
                            .foregroundStyle(Color("BaniSecondaryInk"))
                            .lineLimit(1)
                    }
                    contextTag
                }
            }

            Spacer(minLength: 8)

            amountText
        }
        .padding(.vertical, 4)
    }

    private var categoryIcon: some View {
        Image(systemName: transaction.category?.systemImage ?? "circle.dashed")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color("BaniSecondaryInk"))
            .frame(width: 32, height: 32)
            .background(Color("BaniCanvas"), in: Circle())
    }

    private var contextTag: some View {
        Text(transaction.context.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(transaction.context.tagColorName))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(transaction.context.tagColorName).opacity(0.15), in: Capsule())
    }

    /// Amount + currency code, `.rounded` `monospacedDigit()`, accent-colored.
    private var amountText: Text {
        (
            Text(transaction.amount, format: .number.precision(.fractionLength(0...2)))
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(Color("BaniAccent"))
            + Text(" \(transaction.currency.displayCode)")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color("BaniSecondaryInk"))
        )
        .monospacedDigit()
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
