import SwiftUI
import SwiftData

/// Settings → Import history (C6). Starts a new import and lists past batches
/// (file, date, count) with per-batch undo (same mechanism as the summary undo).
struct ImportHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics
    @Query(sort: \ImportBatch.importedAt, order: .reverse) private var batches: [ImportBatch]

    @State private var showWizard = false
    @State private var pendingUndo: ImportBatch?

    var body: some View {
        Form {
            Section {
                Button {
                    showWizard = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Palette.accent)
                        Text("import.history.new")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Palette.ink)
                        Spacer()
                    }
                }
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("import.history.newButton")
            } footer: {
                Text("import.history.footer").foregroundStyle(Palette.secondaryInk)
            }

            if batches.isEmpty {
                Section {
                    Text("import.history.empty")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .listRowBackground(Palette.surface)
                }
            } else {
                Section {
                    ForEach(batches, id: \.id) { batch in
                        batchRow(batch)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingUndo = batch
                                } label: {
                                    Label("import.summary.undo", systemImage: "arrow.uturn.backward")
                                }
                            }
                    }
                } header: {
                    Text("import.history.past").foregroundStyle(Palette.secondaryInk)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("import.title")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showWizard) {
            ImportWizardView()
        }
        .confirmationDialog(
            Text("import.summary.undo.confirm \(pendingUndo.map { ImportBatchStore.transactionCount(batchID: $0.id, in: modelContext) } ?? 0)"),
            isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } }),
            titleVisibility: .visible
        ) {
            Button("import.summary.undo", role: .destructive) {
                if let batch = pendingUndo {
                    ImportBatchStore.undo(batchID: batch.id, in: modelContext)
                }
                pendingUndo = nil
            }
            Button("Cancel", role: .cancel) { pendingUndo = nil }
        }
    }

    private func batchRow(_ batch: ImportBatch) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(batch.fileName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(batch.rowCount)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            HStack {
                Text(batch.importedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondaryInk)
                if batch.skippedCount > 0 {
                    Text("import.history.skippedInline \(batch.skippedCount)")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
        }
        .padding(.vertical, metrics.rowVInset)
        .listRowBackground(Palette.surface)
        .accessibilityIdentifier("import.history.batchRow")
    }
}
