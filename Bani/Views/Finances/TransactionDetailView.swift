import SwiftUI
import SwiftData

/// Read-first detail for a saved `Transaction`, pushed when a Finances row is
/// tapped (replacing the old land-straight-on-a-blank-edit-sheet behaviour).
/// Editing is now explicit: the Edit button opens the pre-filled edit sheet.
/// Delete stays a swipe on the list — there is deliberately no delete button here.
struct TransactionDetailView: View {
    @Environment(RateService.self) private var rates

    let transaction: Transaction

    @State private var isEditPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                amountHero

                if let other = otherCurrency {
                    conversionLine(other)
                }

                HStack(spacing: 8) {
                    categoryChip
                    contextTag
                    Spacer()
                }

                detailsSection

                if transaction.source == .voice,
                   let raw = transaction.rawTranscript,
                   !raw.isEmpty {
                    transcriptSection(raw)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color("BaniCanvas").ignoresSafeArea())
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditPresented = true }
                    .accessibilityIdentifier("detail.editButton")
            }
        }
        .sheet(isPresented: $isEditPresented) {
            TransactionEditSheet(transaction: transaction)
        }
    }

    // MARK: - Amount + conversion

    private var amountHero: some View {
        (
            Text(transaction.amount, format: .number.precision(.fractionLength(0...2)))
                .font(.system(size: 52, design: .rounded).weight(.bold))
            + Text(" \(transaction.currency.symbol)")
                .font(.system(.title, design: .rounded).weight(.semibold))
        )
        .monospacedDigit()
        .foregroundStyle(Color("BaniAccent"))
        .accessibilityIdentifier("detail.amount")
    }

    /// The OTHER currency at the cached BNR rate: a EUR entry shows its RON
    /// equivalent (× rate), a RON entry shows its EUR equivalent (÷ rate).
    /// `nil` — and the line is omitted entirely — when no rate has been cached
    /// (never guess).
    private var otherCurrency: (value: Decimal, code: String)? {
        guard let rate = rates.rate, rate > 0 else { return nil }
        switch transaction.currency {
        case .eur:
            return (transaction.amount * Decimal(rate), Currency.ron.displayCode)
        case .ron:
            return (transaction.amount / Decimal(rate), Currency.eur.displayCode)
        }
    }

    private func conversionLine(_ other: (value: Decimal, code: String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (
                Text("≈ ")
                + Text(other.value, format: .number.precision(.fractionLength(2)))
                + Text(" \(other.code)")
            )
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color("BaniInk"))

            if let rate = rates.rate {
                Text(bnrCaption(rate: rate))
                    .font(.caption2)
                    .foregroundStyle(Color("BaniSecondaryInk"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.conversion")
    }

    private func bnrCaption(rate: Double) -> String {
        let base = "1 EUR = \(rate.formatted(.number.precision(.fractionLength(2)))) RON"
        if let date = rates.bnrPublishingDate { return base + " · BNR \(date)" }
        return base
    }

    // MARK: - Tags

    private var categoryChip: some View {
        HStack(spacing: 5) {
            Image(systemName: transaction.category?.systemImage ?? "square.grid.2x2.fill")
            Text(transaction.category?.label ?? "Uncategorized")
        }
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color("BaniAccent").opacity(0.14), in: Capsule())
        .foregroundStyle(Color("BaniAccent"))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.categoryChip")
    }

    private var contextTag: some View {
        Text(transaction.context.label)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(transaction.context.tagColorName).opacity(0.2), in: Capsule())
            .foregroundStyle(Color(transaction.context.tagColorName))
            .accessibilityIdentifier("detail.contextTag")
    }

    // MARK: - Details + transcript

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transaction.descriptionText.isEmpty ? "No description" : transaction.descriptionText)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(Color("BaniInk"))

            if let merchant = transaction.merchant, !merchant.isEmpty {
                Text(merchant)
                    .font(.subheadline)
                    .foregroundStyle(Color("BaniSecondaryInk"))
            }

            Text(transaction.date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transcriptSection(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("BaniSecondaryInk"))
            Text("“\(raw)”")
                .font(.system(.body, design: .rounded))
                .italic()
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("detail.transcript")
    }
}

#Preview {
    NavigationStack {
        TransactionDetailView(transaction: Transaction(
            amount: 52, currency: .ron, context: .personal, category: .fuel,
            descriptionText: "benzină", merchant: "OMV",
            rawTranscript: "cincizeci și doi de lei benzină", source: .voice
        ))
    }
    .environment(RateService())
}
