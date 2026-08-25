import SwiftUI
import SwiftData

/// The Loans surface (v1.2b) — the debt tracking screen the whiteboard's Board 2
/// calls for: bank loans and investor / non-bank money in one list, each showing
/// sum owed left, % left, and the next payment. Reached from the Projects tab
/// (the P7 hub later surfaces these loan lines); built in the existing metal
/// style. Create from the toolbar; tap a loan for its amortization detail.
///
/// Standalone `NavigationStack` so it previews/embeds on its own. To hang it off
/// the Projects tab, the orchestrator adds one entry point in `ProjectsView`
/// (a toolbar button or card presenting/pushing this view) — that file is outside
/// this worker's lane, so the wiring is left as a single-line integration.
struct LoansListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale

    @Query(sort: [SortDescriptor(\Loan.createdAt, order: .reverse)]) private var loans: [Loan]
    @Query private var scheduledItems: [ScheduledItem]

    @State private var creating = false

    private var activeLoans: [Loan] { loans.filter { $0.status == .active } }
    private var closedLoans: [Loan] { loans.filter { $0.status == .closed } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: metrics.sectionSpacing) {
                    if loans.isEmpty {
                        emptyState
                    } else {
                        ForEach(activeLoans, id: \.id) { loanCard($0) }
                        if !closedLoans.isEmpty { closedDisclosure }
                    }
                }
                .padding(.horizontal, metrics.screenPadding)
                .padding(.vertical, metrics.elementSpacing)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("loans.title")
            .navigationDestination(for: Loan.self) { loan in
                LoanDetailView(loan: loan)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("loans.createButton")
                    .accessibilityLabel(Text("loans.create"))
                }
            }
            .sheet(isPresented: $creating) {
                LoanEditSheet(loan: nil)
            }
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func loanCard(_ loan: Loan) -> some View {
        NavigationLink(value: loan) {
            LoanCardContent(
                loan: loan.snapshot,
                position: LoanStore.position(for: loan, in: modelContext),
                nextDue: nextDue(for: loan.id)
            )
        }
        .buttonStyle(.plain)
    }

    private var closedDisclosure: some View {
        DisclosureGroup {
            ForEach(closedLoans, id: \.id) { loan in
                NavigationLink(value: loan) {
                    LoanCardContent(
                        loan: loan.snapshot,
                        position: LoanStore.position(for: loan, in: modelContext),
                        nextDue: nil
                    )
                    .opacity(0.7)
                }
                .buttonStyle(.plain)
            }
        } label: {
            Text("loans.closed \(closedLoans.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
        }
        .accentColor(Palette.secondaryInk)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("loans.closedDisclosure")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "banknote")
                .font(.system(size: 42))
                .foregroundStyle(Palette.secondaryInk)
            Text("loans.empty.title")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Text("loans.empty.body")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
            Button {
                creating = true
            } label: {
                Text("loans.empty.cta")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: DesignMetrics.minTapTarget)
            }
            .buttonStyle(MetalPlateButtonStyle(cornerRadius: Radius.button, accentWash: true))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("loans.emptyState")
    }

    // MARK: - Derived

    private func nextDue(for loanID: UUID) -> Date? {
        scheduledItems
            .filter { $0.loanID == loanID && $0.status == .pending }
            .map(\.dueDate)
            .min()
    }
}

// MARK: - Kind badge (shared with the detail view)

/// Small "Bank / Investor" pill for loan cards + the detail header.
struct LoanKindBadge: View {
    let kind: LoanKind

    private var tint: Color { kind == .bank ? Palette.accent : Palette.secondaryInk }

    var body: some View {
        Label(kind.label, systemImage: kind.systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { Capsule().fill(tint.opacity(0.16)) }
            .foregroundStyle(tint)
            .accessibilityIdentifier("loan.kindBadge")
    }
}

// MARK: - Card content

/// A single Cold-Metal loan card: name + lender, kind pill, sum-owed-left hero,
/// % left, and the next payment date. Pure function of the snapshot + position.
struct LoanCardContent: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale
    let loan: LoanSnapshot
    let position: LoanStore.LoanPosition
    let nextDue: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: 8) {
                Text(loan.name)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                LoanKindBadge(kind: loan.kind)
            }

            Text(loan.lender)
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
                .lineLimit(1)

            // Sum owed left — the card's hero number.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(position.outstanding, format: .number.precision(.fractionLength(0...2)))
                    .font(Typography.amount(.title2, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text(loan.currency.displayCode)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .accessibilityIdentifier("loan.card.owed")

            HStack {
                Text("loan.card.percentLeft \(percentText)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
                Spacer()
                if let nextDue {
                    Label(dueText(nextDue), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryInk)
                        .accessibilityIdentifier("loan.card.nextDue")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("loan.card")
    }

    private var percentText: String {
        "\(position.percentLeft.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func dueText(_ date: Date) -> String {
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return String(localized: "loan.card.due \(day)")
    }
}
