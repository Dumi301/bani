import SwiftUI
import SwiftData

/// Balance reconciliation (v2). The client enters their real bank balance; the
/// sheet shows the app's expected balance, the actual, and the signed drift, then
/// offers two commits:
/// - **Create adjustment** — write a closing `Transaction` that reconciles the
///   drift (so the portfolio's net logged position equals reality) AND record an
///   anchor at the entered balance.
/// - **Just anchor** — record the reality point and reset the drift baseline
///   without writing any adjustment (accept the number going forward).
///
/// Self-contained: it reads its own `@Query`s and `modelContext`, so it hangs off
/// the portfolio header with a single presentation and touches no shared surface.
/// All math is `ReconciliationEngine` (pure); all writes are `ReconciliationStore`.
struct ReconciliationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var transactions: [Transaction]
    @Query(sort: [SortDescriptor(\BalanceAnchor.anchoredAt, order: .reverse)])
    private var anchors: [BalanceAnchor]

    @State private var amountText: String = ""
    @State private var currency: Currency = .ron
    @State private var note: String = ""
    @State private var showingHistory = false
    /// Set once from the latest anchor's currency on first appear, so the currency
    /// picker defaults to the account the client last reconciled.
    @State private var didSeedCurrency = false

    // MARK: - Derived (pure)

    private var parsedAmount: Decimal? {
        let cleaned = amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return cleaned.isEmpty ? nil : Decimal(string: cleaned)
    }

    private var latestAnchorForCurrency: BalanceAnchor? {
        anchors.first { $0.currency == currency }   // anchors are sorted newest-first
    }

    private var reconFlows: [ReconciliationFlow] {
        transactions.map {
            ReconciliationFlow(amount: $0.amount, currency: $0.currency,
                               direction: $0.direction, date: $0.date)
        }
    }

    private var result: ReconciliationResult? {
        guard let actual = parsedAmount else { return nil }
        let anchor = latestAnchorForCurrency.map {
            ReconciliationAnchor(amount: $0.amount, currency: $0.currency, anchoredAt: $0.anchoredAt)
        }
        return ReconciliationEngine.reconcile(actual: actual, currency: currency, anchor: anchor, flows: reconFlows)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                balanceSection
                if let result {
                    driftSection(result)
                    actionSection(result)
                }
                noteSection
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("reconcile.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("reconcile.cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .tint(Palette.accent)
                    .disabled(anchors.isEmpty)
                    .accessibilityIdentifier("reconcile.historyButton")
                    .accessibilityLabel(Text("reconcile.history.title"))
                }
            }
            .sheet(isPresented: $showingHistory) {
                ReconciliationHistoryView(anchors: anchors.map(\.snapshot))
            }
            .onAppear(perform: seedCurrencyIfNeeded)
        }
    }

    // MARK: - Sections

    private var balanceSection: some View {
        Section {
            HStack {
                TextField("0", text: $amountText)
                    .keyboardType(.numbersAndPunctuation)
                    .font(Typography.amount(.title3, weight: .semibold))
                    .accessibilityIdentifier("reconcile.amountField")
                Picker("Currency", selection: $currency) {
                    ForEach(Currency.allCases, id: \.self) { c in Text(c.displayCode).tag(c) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("reconcile.currencyToggle")
            }
        } header: {
            Text("reconcile.section.actual")
        } footer: {
            Text("reconcile.section.actual.help")
        }
        .listRowBackground(Palette.surface)
    }

    @ViewBuilder
    private func driftSection(_ result: ReconciliationResult) -> some View {
        Section {
            amountRow(labelKey: "reconcile.expected", value: result.expected, id: "reconcile.expected")
            amountRow(labelKey: "reconcile.actual", value: result.actual, id: "reconcile.actual")
            HStack {
                Text("reconcile.drift")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(signedText(result.drift))
                    .font(Typography.amount(.title3, weight: .bold))
                    .foregroundStyle(driftColor(result.drift))
            }
            .accessibilityIdentifier("reconcile.drift")
            if result.excludedCurrencyFlows > 0 {
                Text("reconcile.excludedCurrency \(result.excludedCurrencyFlows)")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }
            if result.isBalanced {
                Label("reconcile.balanced", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("reconcile.balanced")
            }
        } header: {
            Text("reconcile.section.result")
        }
        .listRowBackground(Palette.surface)
    }

    @ViewBuilder
    private func actionSection(_ result: ReconciliationResult) -> some View {
        Section {
            Button {
                createAdjustment(result)
            } label: {
                Text("reconcile.action.createAdjustment")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: DesignMetrics.minTapTarget)
            }
            .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
            .disabled(result.isBalanced)
            .accessibilityIdentifier("reconcile.createAdjustment")

            Button {
                justAnchor(result)
            } label: {
                Text("reconcile.action.justAnchor")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: DesignMetrics.minTapTarget)
            }
            .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button))
            .accessibilityIdentifier("reconcile.justAnchor")
        } footer: {
            Text("reconcile.action.help")
        }
        .listRowBackground(Color.clear)
    }

    private var noteSection: some View {
        Section {
            TextField("reconcile.note.placeholder", text: $note, axis: .vertical)
                .accessibilityIdentifier("reconcile.noteField")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Row helpers

    private func amountRow(labelKey: LocalizedStringKey, value: Decimal, id: String) -> some View {
        HStack {
            Text(labelKey)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
            Spacer()
            Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(currency.displayCode)")
                .font(Typography.amount(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .accessibilityIdentifier(id)
    }

    private func signedText(_ value: Decimal) -> String {
        let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
        return "\(sign)\(value.magnitude.formatted(.number.precision(.fractionLength(0...2)))) \(currency.displayCode)"
    }

    private func driftColor(_ value: Decimal) -> Color {
        value > 0 ? Palette.accent : (value < 0 ? Palette.ink : Palette.secondaryInk)
    }

    // MARK: - Commit

    private func createAdjustment(_ result: ReconciliationResult) {
        ReconciliationStore.createAdjustmentAndAnchor(
            result: result, note: note, now: Date(),
            referenceDate: latestAnchorForCurrency?.anchoredAt, in: modelContext
        )
        dismiss()
    }

    private func justAnchor(_ result: ReconciliationResult) {
        ReconciliationStore.anchorOnly(result: result, note: note, now: Date(), in: modelContext)
        dismiss()
    }

    private func seedCurrencyIfNeeded() {
        guard !didSeedCurrency else { return }
        didSeedCurrency = true
        if let latest = anchors.first { currency = latest.currency }
    }
}

// MARK: - Anchor history

/// The anchor-history list (date, amount, drift-at-time), reachable from the
/// reconcile sheet. Read-only — a ledger of recorded cash-truth points.
struct ReconciliationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let anchors: [BalanceAnchorSnapshot]

    var body: some View {
        NavigationStack {
            List {
                if anchors.isEmpty {
                    Text("reconcile.history.empty")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .listRowBackground(Palette.surface)
                } else {
                    ForEach(anchors) { anchor in
                        row(anchor)
                            .listRowBackground(Palette.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("reconcile.history.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Palette.accent)
                        .accessibilityIdentifier("reconcile.history.done")
                }
            }
        }
    }

    private func row(_ anchor: BalanceAnchorSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(anchor.amount.formatted(.number.precision(.fractionLength(0...2)))) \(anchor.currency.displayCode)")
                    .font(Typography.amount(.subheadline, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(anchor.anchoredAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale)))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer()
            Text(driftText(anchor.driftAtAnchor))
                .font(.caption.weight(.medium))
                .foregroundStyle(anchor.driftAtAnchor == 0 ? Palette.secondaryInk : Palette.ink)
        }
        .accessibilityIdentifier("reconcile.history.row")
    }

    private func driftText(_ value: Decimal) -> String {
        let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
        let magnitude = value.magnitude.formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: "reconcile.history.drift \("\(sign)\(magnitude)")")
    }
}
