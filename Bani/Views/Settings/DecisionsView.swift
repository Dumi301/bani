import SwiftUI
import SwiftData

/// B5 — the read-only window into the memory forming. Shows overall ask/confirm/
/// correct counts, per-category-rule trailing accuracy + trust state, and the
/// learned context rules. Minimalist and non-interactive — this only reflects the
/// ledger, it never edits it.
struct DecisionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Query private var categoryRules: [CategoryRule]
    @Query private var customCategories: [CustomCategory]
    @Query(sort: \ContextRule.confirmations, order: .reverse) private var contextRules: [ContextRule]

    private struct RuleRow: Identifiable {
        let id: UUID
        let keyword: String
        let ref: CategoryRef
        let accuracy: Double
        let count: Int
        let trusted: Bool
    }

    var body: some View {
        List {
            overallSection
            categoryRuleSection
            contextRuleSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("Decisions")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Overall counts

    private var overallSection: some View {
        Section {
            let counts = DecisionLedger.counts(in: modelContext)
            statRow(String(localized: "decisions.asked"), counts.asked)
            statRow(String(localized: "decisions.confirmed"), counts.confirmed)
            statRow(String(localized: "decisions.corrected"), counts.corrected)
            statRow(String(localized: "decisions.discarded"), counts.discarded)
        } header: {
            Text("Overall").foregroundStyle(Palette.secondaryInk)
        } footer: {
            Text("Every confirmation card writes one decision here. Accumulated decisions decide which guesses the app stops asking about.")
                .foregroundStyle(Palette.secondaryInk)
        }
    }

    private func statRow(_ label: String, _ value: Int) -> some View {
        LabeledContent(label) {
            Text("\(value)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Palette.secondaryInk)
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Category-rule trust

    private var categoryRuleSection: some View {
        Section {
            let rows = ruleStats()
            if rows.isEmpty {
                Text("No category decisions yet")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Palette.surface)
            } else {
                let customs = customCategories.lookup
                ForEach(rows) { row in
                    let style = categoryStyle(row.ref, customs: customs)
                    HStack(spacing: metrics.elementSpacing) {
                        Image(systemName: style.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style.color)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.keyword)
                                .font(.system(.subheadline).weight(.medium))
                                .foregroundStyle(Palette.ink)
                            Text("\(style.label) · \(CountLabels.decisions(row.count))")
                                .font(.caption2)
                                .foregroundStyle(Palette.secondaryInk)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int((row.accuracy * 100).rounded()))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Palette.ink)
                            Text(row.trusted ? String(localized: "decisions.trusted") : String(localized: "decisions.asking"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(row.trusted ? Palette.accent : Palette.secondaryInk)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
        } header: {
            Text("Category rules").foregroundStyle(Palette.secondaryInk)
        } footer: {
            Text("Trailing accuracy over each rule's last 20 decisions. A rule becomes Trusted at ≥95% with ≥10 decisions and auto-saves; it drops back to Asking below 90%.")
                .foregroundStyle(Palette.secondaryInk)
        }
    }

    private func ruleStats() -> [RuleRow] {
        let records = DecisionLedger.allRecords(in: modelContext)
        var samplesByRule: [UUID: [Bool]] = [:]
        for record in records {
            guard let ruleID = record.firedRuleID, let sample = record.outcome.trustSample else { continue }
            samplesByRule[ruleID, default: []].append(sample)
        }
        return categoryRules.compactMap { rule -> RuleRow? in
            guard let samples = samplesByRule[rule.id], !samples.isEmpty else { return nil }
            let (accuracy, count) = TrustEngine.trailingAccuracy(samples)
            return RuleRow(
                id: rule.id,
                keyword: rule.keyword,
                ref: rule.ref,
                accuracy: accuracy,
                count: count,
                trusted: TrustEngine.isTrusted(samples)
            )
        }
        .sorted { $0.count > $1.count }
    }

    // MARK: - Context rules

    private var contextRuleSection: some View {
        Section {
            if contextRules.isEmpty {
                Text("No context rules learned yet")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Palette.surface)
            } else {
                ForEach(contextRules, id: \.id) { rule in
                    HStack(spacing: metrics.elementSpacing) {
                        Text(rule.keyword)
                            .font(.system(.subheadline).weight(.medium))
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text(rule.context.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(rule.context.tagColorName))
                        Text("×\(rule.confirmations)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    .listRowBackground(Palette.surface)
                }
            }
        } header: {
            Text("Context rules").foregroundStyle(Palette.secondaryInk)
        } footer: {
            Text("A keyword pre-selects its context once it has ≥3 confirmations and ≥80% of that keyword's saves.")
                .foregroundStyle(Palette.secondaryInk)
        }
    }
}
