import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Backup (P1, v2). Export the full 13-entity store to a single
/// `.bani-backup` file (share sheet); restore from a picked file, with a typed
/// "store not empty" gate that offers an explicit, twice-confirmed
/// erase-and-restore. On-device only, sideloaded, two phones — this is the ONE
/// way a lost phone doesn't mean losing years of financial data.
struct BackupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.metrics) private var metrics

    // Export
    @State private var isExporting = false
    @State private var exportedArchiveURL: URL?
    @State private var exportErrorMessage: String?

    // Restore
    @State private var isImporterPresented = false
    @State private var isRestoring = false
    @State private var pendingRestoreURL: URL?
    @State private var pendingRestoreTotal: Int?
    @State private var pendingEraseCounts: [BackupEntity: Int]?
    @State private var restoreSummary: BackupManifest?
    @State private var restoreErrorMessage: String?

    private var backupContentType: UTType {
        UTType(filenameExtension: "bani-backup") ?? .data
    }

    var body: some View {
        Form {
            Section {
                exportRow
                restoreRow
            } header: {
                Text("backup.title").foregroundStyle(Palette.secondaryInk)
            } footer: {
                Text("backup.footer").foregroundStyle(Palette.secondaryInk)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("backup.title")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [backupContentType]) { result in
            switch result {
            case .success(let url): Task { await peekAndConfirm(url) }
            case .failure: break
            }
        }
        // Step 1 — restore into (presumed) empty store.
        .confirmationDialog(
            Text("backup.restore.confirm.message \(pendingRestoreTotal ?? 0)"),
            isPresented: Binding(
                get: { pendingRestoreURL != nil && pendingEraseCounts == nil },
                set: { if !$0 { pendingRestoreURL = nil; pendingRestoreTotal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("backup.restore.button") { Task { await runRestore() } }
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil; pendingRestoreTotal = nil }
        } message: {
            Text("backup.restore.confirm.title")
        }
        // Step 2 — the store was NOT empty: explicit, named, destructive confirm.
        .confirmationDialog(
            Text("backup.restore.erase.confirm.message \(pendingEraseCounts.map(totalCount) ?? 0)"),
            isPresented: Binding(
                get: { pendingEraseCounts != nil },
                set: { if !$0 { pendingEraseCounts = nil; pendingRestoreURL = nil; pendingRestoreTotal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("backup.restore.erase.button", role: .destructive) { Task { await runEraseAndRestore() } }
            Button("Cancel", role: .cancel) { pendingEraseCounts = nil; pendingRestoreURL = nil; pendingRestoreTotal = nil }
        } message: {
            Text("backup.restore.erase.confirm.title")
        }
        .alert(
            "backup.restore.summary.title",
            isPresented: Binding(get: { restoreSummary != nil }, set: { if !$0 { restoreSummary = nil } })
        ) {
            Button("OK", role: .cancel) { restoreSummary = nil }
        } message: {
            Text(summaryText(restoreSummary))
        }
        .alert(
            "backup.error.title",
            isPresented: Binding(get: { restoreErrorMessage != nil }, set: { if !$0 { restoreErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { restoreErrorMessage = nil }
        } message: {
            Text(restoreErrorMessage ?? "")
        }
        .alert(
            "backup.error.title",
            isPresented: Binding(get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    // MARK: - Export row

    @ViewBuilder
    private var exportRow: some View {
        VStack(alignment: .leading, spacing: metrics.elementSpacing) {
            if let url = exportedArchiveURL {
                ShareLink(item: url) {
                    Label("backup.export.button", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Palette.ink)
                }
                .accessibilityIdentifier("backup.export.shareLink")
            } else {
                Button {
                    Task { await runExport() }
                } label: {
                    HStack {
                        Label(isExporting ? "backup.export.progress" : "backup.export.button",
                              systemImage: "square.and.arrow.up")
                            .foregroundStyle(Palette.ink)
                        if isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isExporting)
                .accessibilityIdentifier("backup.export.button")
            }
            Text("backup.export.footer")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
        }
        .padding(.vertical, metrics.rowVInset)
        .listRowBackground(Palette.surface)
    }

    private var restoreRow: some View {
        VStack(alignment: .leading, spacing: metrics.elementSpacing) {
            Button {
                isImporterPresented = true
            } label: {
                HStack {
                    Label("backup.restore.button", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(Palette.ink)
                    if isRestoring {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRestoring)
            .accessibilityIdentifier("backup.restore.button")

            Text("backup.restore.footer")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
        }
        .padding(.vertical, metrics.rowVInset)
        .listRowBackground(Palette.surface)
    }

    // MARK: - Export

    private func runExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let archiver = BackupArchiver(modelContainer: modelContext.container)
            let data = try await archiver.makeArchive()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bani-\(exportStamp()).bani-backup")
            try data.write(to: url, options: .atomic)
            exportedArchiveURL = url
        } catch {
            exportErrorMessage = String(localized: "backup.error.corrupt")
        }
    }

    private func exportStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: .now)
    }

    // MARK: - Restore

    private func peekAndConfirm(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            restoreErrorMessage = String(localized: "backup.error.corrupt")
            return
        }
        let restorer = BackupRestorer(modelContainer: modelContext.container)
        do {
            let manifest = try await restorer.peekManifest(archive: data)
            pendingRestoreURL = url
            pendingRestoreTotal = manifest.totalRowCount
        } catch {
            restoreErrorMessage = errorMessage(for: error)
        }
    }

    private func runRestore() async {
        guard let url = pendingRestoreURL else { return }
        isRestoring = true
        defer { isRestoring = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let restorer = BackupRestorer(modelContainer: modelContext.container)
            let manifest = try await restorer.restore(archive: data)
            restoreSummary = manifest
            pendingRestoreURL = nil
            pendingRestoreTotal = nil
        } catch RestoreError.storeNotEmpty(let counts) {
            pendingEraseCounts = counts
        } catch {
            restoreErrorMessage = errorMessage(for: error)
            pendingRestoreURL = nil
            pendingRestoreTotal = nil
        }
    }

    private func runEraseAndRestore() async {
        guard let url = pendingRestoreURL else { return }
        isRestoring = true
        defer { isRestoring = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let restorer = BackupRestorer(modelContainer: modelContext.container)
            let manifest = try await restorer.eraseAndRestore(archive: data)
            restoreSummary = manifest
        } catch {
            restoreErrorMessage = errorMessage(for: error)
        }
        pendingRestoreURL = nil
        pendingRestoreTotal = nil
        pendingEraseCounts = nil
    }

    // MARK: - Display helpers

    private func totalCount(_ counts: [BackupEntity: Int]) -> Int {
        counts.values.reduce(0, +)
    }

    private func summaryText(_ manifest: BackupManifest?) -> String {
        guard let manifest else { return "" }
        return BackupEntity.allCases
            .map { "\($0.label): \(manifest[$0])" }
            .joined(separator: "\n")
    }

    private func errorMessage(for error: Error) -> String {
        guard let restoreError = error as? RestoreError else {
            return String(localized: "backup.error.corrupt")
        }
        switch restoreError {
        case .unsupportedVersion:
            return String(localized: "backup.error.unsupportedVersion")
        case .corruptArchive:
            return String(localized: "backup.error.corrupt")
        case .storeNotEmpty:
            return String(localized: "backup.error.storeNotEmpty")
        }
    }
}

#Preview {
    NavigationStack {
        BackupView()
    }
}
