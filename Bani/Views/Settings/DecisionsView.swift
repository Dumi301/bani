import SwiftUI
import SwiftData

/// B5 — the read-only window into the memory forming. Shows overall ask/confirm/
/// correct counts, per-category-rule trailing accuracy + trust state, and the
/// learned context rules. Minimalist and non-interactive — this only reflects the
/// ledger, it never edits it.
struct DecisionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var categoryRules: [CategoryRule]
    @Query(sort: \ContextRule.confirmations, order: .reverse) private var contextRules: [ContextRule]

    private struct RuleRow: Identifiable {
        let id: UUID
        let keyword: String
        let category: TransactionCategory
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
        .background(Color("BaniCanvas").ignoresSafeArea())
        .navigationTitle("Decisions")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Overall counts

    private var overallSection: some View {
        Section {
            let counts = DecisionLedger.counts(in: modelContext)
            statRow("Asked", counts.asked)
            statRow("Confirmed", counts.confirmed)
            statRow("Corrected", counts.corrected)
            statRow("Discarded", counts.discarded)
        } header: {
            Text("Overall").foregroundStyle(Color("BaniSecondaryInk"))
        } footer: {
            Text("Every confirmation card writes one decision here. Accumulated decisions decide which guesses the app stops asking about.")
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
    }

    private func statRow(_ label: String, _ value: Int) -> some View {
        LabeledContent(label) {
            Text("\(value)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
        .listRowBackground(Color("BaniSurface"))
    }

    // MARK: - Category-rule trust

    private var categoryRuleSection: some View {
        Section {
            let rows = ruleStats()
            if rows.isEmpty {
                Text("No category decisions yet")
                    .font(.subheadline)
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .listRowBackground(Color("BaniSurface"))
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.category.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color("BaniAccent"))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.keyword)
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .foregroundStyle(Color("BaniInk"))
                            Text("\(row.category.label) · \(row.count) decision\(row.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(Color("BaniSecondaryInk"))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int((row.accuracy * 100).rounded()))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Color("BaniInk"))
                            Text(row.trusted ? "Trusted" : "Asking")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(row.trusted ? Color("BaniAccent") : Color("BaniSecondaryInk"))
                        }
                    }
                    .listRowBackground(Color("BaniSurface"))
                }
            }
        } header: {
            Text("Category rules").foregroundStyle(Color("BaniSecondaryInk"))
        } footer: {
            Text("Trailing accuracy over each rule's last 20 decisions. A rule becomes Trusted at ≥95% with ≥10 decisions and auto-saves; it drops back to Asking below 90%.")
                .foregroundStyle(Color("BaniSecondaryInk"))
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
                category: rule.category,
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
                    .foregroundStyle(Color("BaniSecondaryInk"))
                    .listRowBackground(Color("BaniSurface"))
            } else {
                ForEach(contextRules, id: \.id) { rule in
                    HStack {
                        Text(rule.keyword)
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(Color("BaniInk"))
                        Spacer()
                        Text(rule.context.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(rule.context.tagColorName))
                        Text("×\(rule.confirmations)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color("BaniSecondaryInk"))
                    }
                    .listRowBackground(Color("BaniSurface"))
                }
            }
        } header: {
            Text("Context rules").foregroundStyle(Color("BaniSecondaryInk"))
        } footer: {
            Text("A keyword pre-selects its context once it has ≥3 confirmations and ≥80% of that keyword's saves.")
                .foregroundStyle(Color("BaniSecondaryInk"))
        }
    }
}
