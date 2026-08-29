import SwiftUI
import SwiftData

/// The Projects tab (new top-level tab, between Log and Finances). Projects are
/// analytical *lenses* over the single cash pot — never wallets. Top to bottom:
/// the always-on portfolio header (the liquidity answer), then a grid of project
/// cards, then an "Archived" disclosure. Create from the toolbar; rename / finish
/// / archive from a card's context menu. Deleting a project that has transactions
/// is disallowed — archive instead (its transactions keep their `projectID`).
struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RateService.self) private var rates
    @Environment(\.locale) private var locale
    @Environment(\.metrics) private var metrics

    @Query(sort: [SortDescriptor(\Project.sortOrder), SortDescriptor(\Project.createdAt, order: .reverse)])
    private var projects: [Project]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var scheduledItems: [ScheduledItem]

    @AppStorage("projectsHorizon") private var horizonRaw: Int = LiquidityHorizon.days30.rawValue

    /// Per-card RON⇄EUR display flip, session-sticky (lives with this view).
    @State private var eurCardIDs: Set<UUID> = []
    @State private var creatingProject = false
    @State private var renamingProject: Project?
    /// v1.2b — presents the Loans surface (bank + investor debt) from this tab.
    @State private var showingLoans = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: metrics.sectionSpacing) {
                    PortfolioHeaderView(
                        netLoggedPosition: netLoggedPosition,
                        liquidity: liquidity,
                        horizon: horizonBinding,
                        bnrDate: rates.bnrPublishingDate,
                        rate: rates.rate
                    )

                    if activeProjects.isEmpty {
                        emptyState
                    } else {
                        ForEach(activeProjects, id: \.id) { project in
                            projectCard(project)
                        }
                    }

                    if !archivedProjects.isEmpty {
                        archivedDisclosure
                    }
                }
                .padding(.horizontal, metrics.screenPadding)
                .padding(.vertical, metrics.elementSpacing)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("projects.title")
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project)
            }
            // Dashboard / Documents panes push transaction detail from this stack.
            .navigationDestination(for: Transaction.self) { transaction in
                TransactionDetailView(transaction: transaction)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingLoans = true
                    } label: {
                        Image(systemName: "banknote")
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("projects.loansButton")
                    .accessibilityLabel(Text("loans.title"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creatingProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("projects.createButton")
                    .accessibilityLabel(Text("projects.create"))
                }
            }
            .sheet(isPresented: $showingLoans) {
                LoansListView()
            }
            .sheet(isPresented: $creatingProject) {
                // v1.3 "People registry" run — the guided interview replaces bare
                // creation; ProjectEditSheet stays the rename/recolor path below.
                ProjectCreationInterviewSheet()
            }
            .sheet(item: $renamingProject) { project in
                ProjectEditSheet(project: project)
            }
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func projectCard(_ project: Project) -> some View {
        let model = cardModel(for: project)
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: project) {
                ProjectCardContent(
                    model: model,
                    showEUR: eurCardIDs.contains(project.id),
                    rate: rates.rate
                )
            }
            .buttonStyle(.plain)

            if model.hasEUR, rates.rate != nil {
                flipButton(for: project.id)
                    .padding(10)
            }
        }
        .contextMenu {
            projectContextMenu(project, hasTransactions: model.hasTransactions)
        }
    }

    private func flipButton(for id: UUID) -> some View {
        Button {
            if eurCardIDs.contains(id) { eurCardIDs.remove(id) } else { eurCardIDs.insert(id) }
        } label: {
            Text(eurCardIDs.contains(id) ? Currency.eur.displayCode : Currency.ron.displayCode)
                .font(.caption2.weight(.bold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .metalSurface(cornerRadius: Radius.chip)
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project.card.currencyFlip")
        .accessibilityLabel(Text("project.card.flip.a11y"))
    }

    @ViewBuilder
    private func projectContextMenu(_ project: Project, hasTransactions: Bool) -> some View {
        Button {
            renamingProject = project
        } label: {
            Label("project.action.rename", systemImage: "pencil")
        }

        Button {
            project.status = (project.status == .active) ? .finished : .active
            try? modelContext.save()
        } label: {
            Label(project.status == .active ? "project.action.finish" : "project.action.reactivate",
                  systemImage: project.status == .active ? "checkmark.seal" : "arrow.counterclockwise")
        }

        Button {
            project.archived = true
            try? modelContext.save()
        } label: {
            Label("project.action.archive", systemImage: "archivebox")
        }

        // Delete is allowed ONLY when the project has no transactions (they would
        // otherwise be orphaned). Otherwise the only removal is Archive.
        if !hasTransactions {
            Button(role: .destructive) {
                modelContext.delete(project)
                try? modelContext.save()
            } label: {
                Label("project.action.delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Archived disclosure

    private var archivedDisclosure: some View {
        DisclosureGroup {
            ForEach(archivedProjects, id: \.id) { project in
                let model = cardModel(for: project)
                ZStack(alignment: .topTrailing) {
                    NavigationLink(value: project) {
                        ProjectCardContent(model: model, showEUR: false, rate: rates.rate)
                            .opacity(0.7)
                    }
                    .buttonStyle(.plain)
                }
                .contextMenu {
                    Button {
                        project.archived = false
                        try? modelContext.save()
                    } label: {
                        Label("project.action.unarchive", systemImage: "tray.and.arrow.up")
                    }
                }
            }
        } label: {
            Text("projects.archived \(archivedProjects.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
        }
        .accentColor(Palette.secondaryInk)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card)
        .accessibilityIdentifier("projects.archivedDisclosure")
    }

    // MARK: - Empty state (teaches the feature, ro + en)

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42))
                .foregroundStyle(Palette.secondaryInk)
            Text("projects.empty.title")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Text("projects.empty.body")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
            Button {
                creatingProject = true
            } label: {
                Text("projects.empty.cta")
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
        .accessibilityIdentifier("projects.emptyState")
    }

    // MARK: - Derived state

    private var horizonBinding: Binding<LiquidityHorizon> {
        Binding(
            get: { LiquidityHorizon(rawValue: horizonRaw) ?? .days30 },
            set: { horizonRaw = $0.rawValue }
        )
    }
    private var horizon: LiquidityHorizon { LiquidityHorizon(rawValue: horizonRaw) ?? .days30 }
    // L5: the exact Decimal rate (`RateService.rateDecimal`), not
    // `rates.rate.map { Decimal($0) }` — see `RateService`'s doc.
    private var rateDecimal: Decimal? { rates.rateDecimal }

    private var activeProjects: [Project] { projects.filter { !$0.archived } }
    private var archivedProjects: [Project] { projects.filter { $0.archived } }

    private var lines: [ProjectTxLine] {
        transactions.map {
            ProjectTxLine(amount: $0.amount, currency: $0.currency, direction: $0.direction,
                          projectID: $0.projectID, date: $0.date)
        }
    }

    private var netLoggedPosition: Decimal {
        ProjectAnalytics.netLoggedPosition(lines, rate: rateDecimal)
    }

    private var pendingSnapshots: [ScheduledItemSnapshot] {
        scheduledItems.filter { $0.status == .pending }.map(\.snapshot)
    }

    private var liquidity: LiquidityResult {
        LiquidityCalculator.result(
            netLoggedPosition: netLoggedPosition,
            pendingItems: pendingSnapshots,
            horizon: horizon,
            rate: rateDecimal
        )
    }

    private func cardModel(for project: Project) -> ProjectCardModel {
        let scoped = ProjectAnalytics.scoped(lines, to: project.id)
        let totals = ProjectAnalytics.totals(scoped, rate: rateDecimal)
        let items = scheduledItems.filter { $0.projectID == project.id }.map(\.snapshot)
        let rollup = ProjectAnalytics.pendingRollup(items, rate: rateDecimal)
        let byCurrency = ProjectAnalytics.totalsByCurrency(scoped)
        return ProjectCardModel(
            id: project.id,
            name: project.name,
            status: project.status,
            colorIndex: project.colorIndex,
            spent: totals.spent,
            net: totals.net,
            expectedIncoming: rollup.incoming,
            expectedOutgoing: rollup.outgoing,
            nearestDue: rollup.nearestDueDate,
            hasEUR: (byCurrency[.eur] ?? 0) > 0,
            hasTransactions: !scoped.isEmpty
        )
    }
}

// MARK: - Card model + content

/// Everything one project card renders, pre-computed (RON-combined) so the card
/// view stays a pure function of value data.
struct ProjectCardModel: Identifiable, Equatable {
    let id: UUID
    let name: String
    let status: ProjectStatus
    let colorIndex: Int
    let spent: Decimal
    let net: Decimal
    let expectedIncoming: Decimal
    let expectedOutgoing: Decimal
    let nearestDue: Date?
    let hasEUR: Bool
    let hasTransactions: Bool

    /// Projected position: net + pending incoming − pending outgoing.
    var projected: Decimal { net + expectedIncoming - expectedOutgoing }
    var color: Color { CustomCategoryPalette.color(colorIndex) }
}

/// A single Cold-Metal project card (density-aware). Primary display is RON; when
/// `showEUR` is on and a rate exists, the money lines flip to EUR equivalents.
struct ProjectCardContent: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale
    let model: ProjectCardModel
    let showEUR: Bool
    let rate: Double?

    private var code: String { (showEUR && rate != nil) ? Currency.eur.displayCode : Currency.ron.displayCode }

    /// Convert a RON figure to the displayed currency (RON pass-through, EUR ÷ rate).
    private func shown(_ ronValue: Decimal) -> Decimal {
        guard showEUR, let rate, rate > 0 else { return ronValue }
        return ronValue / Decimal(rate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: 8) {
                Circle().fill(model.color).frame(width: 10, height: 10)
                Text(model.name)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                ProjectStatusBadge(status: model.status)
            }

            // Net position — the card's hero number.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(shown(model.net), format: .number.precision(.fractionLength(0...2)))
                    .font(Typography.amount(.title2, weight: .bold))
                    .foregroundStyle(model.net < 0 ? Palette.secondaryInk : Palette.accent)
                Text(code)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .accessibilityIdentifier("project.card.net")

            statRow(labelKey: "project.card.spent", value: shown(model.spent))
            if model.expectedIncoming > 0 || model.expectedOutgoing > 0 {
                statRow(labelKey: "project.card.expectedIncome", value: shown(model.expectedIncoming))
                statRow(labelKey: "project.card.projected", value: shown(model.projected))
            }
            if let due = model.nearestDue {
                Label(dueText(due), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
                    .accessibilityIdentifier("project.card.nearestDue")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .metalSurface(cornerRadius: Radius.card, elevated: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.card")
    }

    private func statRow(labelKey: LocalizedStringKey, value: Decimal) -> some View {
        HStack {
            Text(labelKey)
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
            Spacer()
            Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(code)")
                .font(Typography.amount(.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
    }

    private func dueText(_ date: Date) -> String {
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return String(localized: "project.card.due \(day)")
    }
}
