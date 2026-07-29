import SwiftUI
import SwiftData

/// Finances cluster root. Segmented Personal/Work/All filter, grouped
/// transaction list (category/month/merchant), a combined RON hero total
/// (falling back to side-by-side per-currency totals when no BNR rate has
/// ever been fetched), swipe-to-delete with undo, and tap-to-edit.
///
/// Reads `RateService` (owned by Unit G) purely for display per
/// `pipeline/interfaces.md` — this view never triggers a fetch itself.
struct FinancesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RateService.self) private var rates

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    /// Persists only the last-chosen Personal/Work segment — "All" is never
    /// written here, so relaunching after "All" restores the prior Personal/Work choice.
    @AppStorage("financesLastContext") private var lastContextRaw: String = TransactionContext.personal.rawValue
    @AppStorage("financesGrouping") private var groupingRaw: String = TransactionGrouping.category.rawValue

    @State private var selectedFilter: FinancesFilter
    @State private var selectedTransaction: Transaction?
    @State private var recentlyDeleted: DeletedTransactionSnapshot?

    init() {
        let last = UserDefaults.standard.string(forKey: "financesLastContext") ?? TransactionContext.personal.rawValue
        let context = TransactionContext(rawValue: last) ?? .personal
        _selectedFilter = State(initialValue: context == .work ? .work : .personal)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color("BaniCanvas").ignoresSafeArea()

                VStack(spacing: 0) {
                    segmentControl

                    if filteredTransactions.isEmpty {
                        emptyStateView
                    } else {
                        totalsHeader
                            .padding(.horizontal)
                            .padding(.top, 16)

                        GroupingPicker(selection: groupingBinding)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 4)

                        transactionList
                    }
                }
            }
            .navigationTitle("Finances")
            .navigationDestination(item: $selectedTransaction) { transaction in
                TransactionDetailView(transaction: transaction)
            }
            .overlay(alignment: .bottom) {
                if let recentlyDeleted {
                    undoToast(for: recentlyDeleted)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: recentlyDeleted?.id)
        }
    }

    // MARK: - Segment control

    private var segmentControl: some View {
        Picker("Context", selection: $selectedFilter) {
            ForEach(FinancesFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityIdentifier("financesSegmentControl")
        .onChange(of: selectedFilter) { _, newValue in
            switch newValue {
            case .personal: lastContextRaw = TransactionContext.personal.rawValue
            case .work: lastContextRaw = TransactionContext.work.rawValue
            case .all: break
            }
        }
    }

    // MARK: - Totals

    @ViewBuilder
    private var totalsHeader: some View {
        if let rate = rates.rate {
            VStack(spacing: 6) {
                heroTotalText(rate: rate)
                    .accessibilityIdentifier("financesHeroTotal")

                Text(perCurrencyBreakdown(filteredTransactions))
                    .font(.subheadline)
                    .foregroundStyle(Color("BaniSecondaryInk"))

                if let date = rates.bnrPublishingDate {
                    Text("1 EUR = \(rate.formatted(.number.precision(.fractionLength(2)))) RON · BNR \(date)")
                        .font(.caption2)
                        .foregroundStyle(Color("BaniSecondaryInk"))
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            // No rate has ever been fetched — never guess. Side-by-side per-currency totals only.
            HStack(spacing: 32) {
                perCurrencyStat(currency: .ron)
                    .accessibilityIdentifier("financesRonTotal")
                perCurrencyStat(currency: .eur)
                    .accessibilityIdentifier("financesEurTotal")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func heroTotalText(rate: Double) -> some View {
        let combined = filteredTransactions.reduce(Decimal(0)) { sum, tx in
            sum + (rates.ronEquivalent(of: tx.amount, currency: tx.currency) ?? tx.amount)
        }
        return (
            Text(combined, format: .number.precision(.fractionLength(0...2)))
                .font(.system(size: 42, design: .rounded).weight(.bold))
            + Text(" RON")
                .font(.system(.title3, design: .rounded).weight(.semibold))
        )
        .monospacedDigit()
        .foregroundStyle(Color("BaniAccent"))
    }

    private func perCurrencyStat(currency: Currency) -> some View {
        let total = filteredTransactions
            .filter { $0.currency == currency }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return VStack(spacing: 4) {
            Text(total, format: .number.precision(.fractionLength(0...2)))
                .font(.system(size: 34, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color("BaniAccent"))
            Text(currency.displayCode)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
    }

    private func perCurrencyBreakdown(_ transactions: [Transaction]) -> String {
        let grouped = Dictionary(grouping: transactions, by: \.currency)
        let parts = Currency.allCases.compactMap { currency -> String? in
            guard let items = grouped[currency], !items.isEmpty else { return nil }
            let total = items.reduce(Decimal(0)) { $0 + $1.amount }
            return "\(total.formatted(.number.precision(.fractionLength(0...2)))) \(currency.displayCode)"
        }
        return parts.joined(separator: " + ")
    }

    // MARK: - List

    private var transactionList: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.transactions, id: \.id) { transaction in
                        TransactionRow(transaction: transaction)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedTransaction = transaction
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(transaction)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Color("BaniSurface"))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var groupingBinding: Binding<TransactionGrouping> {
        Binding(
            get: { TransactionGrouping(rawValue: groupingRaw) ?? .category },
            set: { groupingRaw = $0.rawValue }
        )
    }

    private var filteredTransactions: [Transaction] {
        switch selectedFilter {
        case .personal: transactions.filter { $0.context == .personal }
        case .work: transactions.filter { $0.context == .work }
        case .all: transactions
        }
    }

    private var groups: [TransactionGroup] {
        makeGroups(from: filteredTransactions, grouping: groupingBinding.wrappedValue)
    }

    private func makeGroups(from transactions: [Transaction], grouping: TransactionGrouping) -> [TransactionGroup] {
        switch grouping {
        case .category:
            let dict = Dictionary(grouping: transactions) { $0.category }
            let orderedKeys: [TransactionCategory?] = TransactionCategory.allCases.map { category in TransactionCategory?.some(category) } + [TransactionCategory?.none]
            return orderedKeys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return TransactionGroup(
                    id: key?.rawValue ?? "uncategorized",
                    title: key?.label ?? "Uncategorized",
                    transactions: items
                )
            }

        case .month:
            let calendar = Calendar.current
            let dict = Dictionary(grouping: transactions) { tx in
                calendar.dateInterval(of: .month, for: tx.date)?.start ?? tx.date
            }
            return dict.keys.sorted(by: >).map { monthStart in
                TransactionGroup(
                    id: monthStart.ISO8601Format(),
                    title: monthStart.formatted(.dateTime.month(.wide).year()),
                    transactions: dict[monthStart] ?? []
                )
            }

        case .merchant:
            let dict = Dictionary(grouping: transactions) { tx -> String? in
                (tx.merchant?.isEmpty == false) ? tx.merchant : nil
            }
            let keys = dict.keys.sorted { lhs, rhs in
                switch (lhs, rhs) {
                case (nil, nil): false
                case (nil, _): false
                case (_, nil): true
                default: (lhs ?? "") < (rhs ?? "")
                }
            }
            return keys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return TransactionGroup(
                    id: key ?? "no-merchant",
                    title: key ?? "No merchant",
                    transactions: items
                )
            }
        }
    }

    // MARK: - Delete + undo

    private func delete(_ transaction: Transaction) {
        let snapshot = DeletedTransactionSnapshot(transaction)
        modelContext.delete(transaction)
        try? modelContext.save()
        withAnimation { recentlyDeleted = snapshot }

        let snapshotID = snapshot.id
        Task {
            try? await Task.sleep(for: .seconds(4))
            if recentlyDeleted?.id == snapshotID {
                withAnimation { recentlyDeleted = nil }
            }
        }
    }

    private func undoDelete() {
        guard let snapshot = recentlyDeleted else { return }
        let restored = Transaction(
            amount: snapshot.amount,
            currency: snapshot.currency,
            context: snapshot.context,
            category: snapshot.category,
            descriptionText: snapshot.descriptionText,
            merchant: snapshot.merchant,
            date: snapshot.date,
            rawTranscript: snapshot.rawTranscript,
            source: snapshot.source,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(restored)
        try? modelContext.save()
        withAnimation { recentlyDeleted = nil }
    }

    @ViewBuilder
    private func undoToast(for snapshot: DeletedTransactionSnapshot) -> some View {
        HStack {
            Text("Transaction deleted")
                .font(.subheadline)
                .foregroundStyle(Color("BaniInk"))
            Spacer()
            Button("Undo") { undoDelete() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color("BaniAccent"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color("BaniSurface"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color("BaniHairline"))
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 40))
                .foregroundStyle(Color("BaniSecondaryInk"))
            Text(emptyStateTitle)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color("BaniInk"))
            Text("Log a purchase from the Log tab and it will show up here, grouped by \(groupingBinding.wrappedValue.label.lowercased()).")
                .font(.subheadline)
                .foregroundStyle(Color("BaniSecondaryInk"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("financesEmptyState")
    }

    private var emptyStateIcon: String {
        switch selectedFilter {
        case .personal: "person.crop.circle"
        case .work: "briefcase.fill"
        case .all: "tray"
        }
    }

    private var emptyStateTitle: String {
        switch selectedFilter {
        case .personal: "No personal transactions yet"
        case .work: "No work transactions yet"
        case .all: "No transactions yet"
        }
    }
}

// MARK: - Supporting types

private enum FinancesFilter: String, CaseIterable, Identifiable, Sendable {
    case personal, work, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personal: "Personal"
        case .work: "Work"
        case .all: "All"
        }
    }
}

private struct TransactionGroup: Identifiable {
    let id: String
    let title: String
    let transactions: [Transaction]
}

/// Captured field values of a deleted transaction so the undo toast can
/// recreate an equivalent record. SwiftData can't "un-delete" the same
/// instance once removed from the context, so undo inserts a fresh one.
private struct DeletedTransactionSnapshot {
    let id = UUID()
    let amount: Decimal
    let currency: Currency
    let context: TransactionContext
    let category: TransactionCategory?
    let descriptionText: String
    let merchant: String?
    let date: Date
    let rawTranscript: String?
    let source: TransactionSource
    let createdAt: Date

    init(_ transaction: Transaction) {
        amount = transaction.amount
        currency = transaction.currency
        context = transaction.context
        category = transaction.category
        descriptionText = transaction.descriptionText
        merchant = transaction.merchant
        date = transaction.date
        rawTranscript = transaction.rawTranscript
        source = transaction.source
        createdAt = transaction.createdAt
    }
}
