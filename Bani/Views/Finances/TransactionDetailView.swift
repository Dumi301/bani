import SwiftUI
import SwiftData

/// Read-first detail for a saved `Transaction`, pushed when a Finances row is
/// tapped (replacing the old land-straight-on-a-blank-edit-sheet behaviour).
/// Editing is now explicit: the Edit button opens the pre-filled edit sheet.
/// Delete stays a swipe on the list — there is deliberately no delete button here.
struct TransactionDetailView: View {
    @Environment(RateService.self) private var rates
    @Environment(\.metrics) private var metrics
    @Query private var customCategories: [CustomCategory]

    let transaction: Transaction

    @State private var isEditPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                amountHero

                if let other = otherCurrency {
                    conversionLine(other)
                }

                HStack(spacing: metrics.elementSpacing) {
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
            .padding(metrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditPresented = true }
                    .fontWeight(.semibold)
                    .tint(Palette.accent)
                    .accessibilityIdentifier("detail.editButton")
            }
        }
        .sheet(isPresented: $isEditPresented) {
            TransactionEditSheet(transaction: transaction)
        }
    }

    // MARK: - Amount + conversion

    private var amountHero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(transaction.amount, format: .number.precision(.fractionLength(0...2)))
                .font(Typography.heroAmount)
            Text(transaction.currency.symbol)
                .font(Typography.amount(.title, weight: .semibold))
        }
        .foregroundStyle(Palette.accent)
        .accessibilityElement(children: .combine)
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
            Text("≈ \(other.value.formatted(.number.precision(.fractionLength(2)))) \(other.code)")
                .font(Typography.amount(.title3, weight: .semibold))
                .foregroundStyle(Palette.ink)

            if let rate = rates.rate {
                Text(bnrCaption(rate: rate))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
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
        let style = categoryStyle(transaction.categoryRef, customs: customCategories.lookup)
        return HStack(spacing: 5) {
            Image(systemName: style.systemImage)
            Text(style.label)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(style.color.opacity(0.16), in: Capsule())
        .foregroundStyle(style.color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.categoryChip")
    }

    private var contextTag: some View {
        Text(transaction.context.label)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(transaction.context.tagColorName).opacity(0.2), in: Capsule())
            .foregroundStyle(Color(transaction.context.tagColorName))
            .accessibilityIdentifier("detail.contextTag")
    }

    // MARK: - Details + transcript

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transaction.descriptionText.isEmpty ? String(localized: "confirm.noDescription") : transaction.descriptionText)
                .font(.title3.weight(.medium))
                .foregroundStyle(Palette.ink)

            if let merchant = transaction.merchant, !merchant.isEmpty {
                Text(merchant)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
            }

            Text(transaction.date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
    }

    private func transcriptSection(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
            Text("“\(raw)”")
                .font(.body)
                .italic()
                .foregroundStyle(Palette.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
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
