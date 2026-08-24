import SwiftUI
import SwiftData

/// The review surface for cross-source possible duplicates (P8). Reached from
/// the Log tab's "N possible duplicates — review" chip — the SAME chip+sheet
/// pattern as the auto-log review (Part A), for a different question: "is this
/// the same real payment as <desc>, logged twice through two different
/// surfaces?" Every resolution is one of:
///   - Keep both — legitimately separate; clears the flag, no data changes.
///   - Merge — the same payment; keeps the richer record, deletes the other,
///     writes one `.corrected` `DecisionRecord` (`.merge`).
/// Nothing here is ever silently dropped: a flagged row is already a real,
/// fully-saved transaction — this review only resolves the FLAG.
struct DedupReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    @Query private var customCategories: [CustomCategory]

    @State private var items: [Transaction] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                if items.isEmpty {
                    ContentUnavailableView {
                        Label("dedup.review.empty", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("dedupReview.empty")
                } else {
                    list
                }
            }
            .navigationTitle("dedup.review.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("autolog.done") { dismiss() }
                        .accessibilityIdentifier("dedupReview.done")
                }
            }
            .onAppear(perform: reload)
        }
    }

    private var list: some View {
        List {
            ForEach(items, id: \.id) { tx in
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    TransactionRow(transaction: tx, customs: customCategories.lookup)
                    if let otherDescription = duplicateDescription(for: tx) {
                        Text("dedup.review.possibleDuplicateOf \(otherDescription)")
                            .font(.system(.caption))
                            .foregroundStyle(Palette.secondaryInk)
                            .accessibilityIdentifier("dedupReview.matchNote")
                    }
                    actionRow(for: tx)
                }
                .padding(.vertical, metrics.rowVInset)
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("dedupReview.list")
    }

    private func duplicateDescription(for tx: Transaction) -> String? {
        DedupService.matchedTransaction(for: tx, in: modelContext)?.descriptionText
    }

    private func actionRow(for tx: Transaction) -> some View {
        HStack(spacing: metrics.rowSpacing) {
            Button {
                DedupService.keepBoth(tx, in: modelContext)
                reload()
            } label: {
                Label("dedup.review.keepBoth", systemImage: "square.on.square")
                    .font(.system(.subheadline).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tint(Palette.ink)
            .accessibilityIdentifier("dedupReview.keepBoth")

            Button {
                DedupService.merge(tx, in: modelContext)
                reload()
            } label: {
                Label("dedup.review.merge", systemImage: "arrow.triangle.merge")
                    .font(.system(.subheadline).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tint(Palette.accent)
            .accessibilityIdentifier("dedupReview.mergeButton")
        }
        .labelStyle(.titleAndIcon)
    }

    private func reload() {
        items = DedupService.flagged(in: modelContext)
    }
}
