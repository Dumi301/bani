import SwiftUI
import SwiftData

/// Inside a loan: the debt position (sum owed left, % left, next payment), a
/// "record payment" action that books the interest/principal split
/// (`LoanStore.bookPayment`), and the full amortization schedule
/// (date · payment · interest · principal · balance). Edit re-syncs pending
/// payments; close cancels the remaining ones.
struct LoanDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale

    let loan: Loan

    @Query private var scheduledItems: [ScheduledItem]
    @State private var editing = false
    @State private var confirmingClose = false

    private var schedule: [AmortizationPayment] { loan.schedule() }
    private var position: LoanStore.LoanPosition { LoanStore.position(for: loan, in: modelContext) }

    /// The earliest still-pending payment item for this loan (the one "record
    /// payment" books next).
    private var nextPendingItem: ScheduledItem? {
        scheduledItems
            .filter { $0.loanID == loan.id && $0.status == .pending }
            .min { $0.dueDate < $1.dueDate }
    }

    var body: some View {
        // Compute the debt position ONCE per render (it fetches transactions), then
        // thread it down — never per schedule row.
        let position = self.position
        let schedule = self.schedule
        return ScrollView {
            LazyVStack(spacing: metrics.sectionSpacing) {
                header(position)
                if loan.status == .active, let next = nextPendingItem {
                    recordButton(next)
                }
                scheduleSection(schedule, paymentsBooked: position.paymentsBooked)
            }
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.elementSpacing)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle(loan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editing = true
                    } label: {
                        Label("loan.action.edit", systemImage: "pencil")
                    }
                    if loan.status == .active {
                        Button(role: .destructive) {
                            confirmingClose = true
                        } label: {
                            Label("loan.action.close", systemImage: "xmark.seal")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("loan.menu")
            }
        }
        .sheet(isPresented: $editing) {
            LoanEditSheet(loan: loan)
        }
        .alert("loan.close.confirm.title", isPresented: $confirmingClose) {
            Button("loan.action.close", role: .destructive) {
                LoanStore.closeLoan(loan, in: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("loan.close.confirm.message")
        }
    }

    // MARK: - Header

    private func header(_ position: LoanStore.LoanPosition) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: 8) {
                Text(loan.lender)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                Spacer(minLength: 6)
                LoanKindBadge(kind: loan.kind)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(position.outstanding, format: .number.precision(.fractionLength(0...2)))
                    .font(Typography.amount(.title, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text(loan.currency.displayCode)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .accessibilityIdentifier("loan.detail.owed")

            statRow(labelKey: "loan.detail.percentLeft",
                    value: "\(position.percentLeft.formatted(.number.precision(.fractionLength(0...1))))%")
            statRow(labelKey: "loan.detail.principal",
                    value: "\(loan.principal.formatted(.number.precision(.fractionLength(0...2)))) \(loan.currency.displayCode)")
            if let next = nextPendingItem {
                statRow(labelKey: "loan.detail.nextPayment",
                        value: "\(next.amount.formatted(.number.precision(.fractionLength(0...2)))) · \(next.dueDate.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))")
            } else if loan.status == .closed {
                statRow(labelKey: "loan.detail.status", value: LoanStatus.closed.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .accessibilityIdentifier("loan.detail.header")
    }

    private func statRow(labelKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(labelKey)
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
            Spacer()
            Text(value)
                .font(Typography.amount(.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
    }

    // MARK: - Record payment

    private func recordButton(_ item: ScheduledItem) -> some View {
        Button {
            LoanStore.bookPayment(item, loan: loan, in: modelContext)
        } label: {
            Label("loan.recordPayment", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
        .accessibilityIdentifier("loan.recordPaymentButton")
    }

    // MARK: - Schedule table

    private func scheduleSection(_ schedule: [AmortizationPayment], paymentsBooked: Int) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            Text("loan.schedule.title")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            if schedule.isEmpty {
                Text("loan.schedule.empty")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(schedule) { row in
                    scheduleRow(row, paid: row.index <= paymentsBooked)
                }
            }
        }
    }

    private func scheduleRow(_ row: AmortizationPayment, paid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("loan.schedule.payment \(row.index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(paid ? Palette.secondaryInk : Palette.ink)
                if paid {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("loan.schedule.paidMark")
                }
                Spacer()
                Text(row.dueDate.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
            }
            HStack(spacing: 0) {
                cell(labelKey: "loan.schedule.col.payment", value: row.payment)
                cell(labelKey: "loan.schedule.col.interest", value: row.interest)
                cell(labelKey: "loan.schedule.col.principal", value: row.principal)
                cell(labelKey: "loan.schedule.col.balance", value: row.balanceAfter)
            }
        }
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .opacity(paid ? 0.7 : 1)
        .accessibilityIdentifier("loan.schedule.row")
    }

    private func cell(labelKey: LocalizedStringKey, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(labelKey)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value.formatted(.number.precision(.fractionLength(0...2))))
                .font(Typography.amount(.caption2, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
