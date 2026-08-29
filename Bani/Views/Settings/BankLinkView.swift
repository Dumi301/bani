import SwiftUI
import SwiftData
import SafariServices

/// P9 — the Settings surface for open-banking. Entirely gated behind this screen:
/// with no keys entered, the rest of the app shows nothing bank-related (the only
/// always-visible affordance is the Settings row that pushes here). Secrets are
/// entered into SecureFields and written straight to the Keychain
/// (`KeychainStore`) — they are never rendered back, never stored elsewhere.
///
/// The link flow opens the GoCardless requisition URL in an in-app
/// `SFSafariViewController` sheet; on return the app polls the requisition until it
/// is linked (no custom URL scheme needed — AltStore-friendly). Pull is manual
/// ("Sync now") here; the app-foreground opportunistic pull is wired by the root.
struct BankLinkView: View {
    @Environment(\.modelContext) private var modelContext

    private let keychain = KeychainStore()
    /// H1 (phase-A): stateless status/throttle wrapper shared with
    /// `BaniApp.syncBankIfNeeded` — read here to show the last-sync time + a
    /// plain error line, and updated after every manual "Sync now" too.
    private let bankSyncGate = BankSyncGate()

    @State private var store: BankLinkStore?
    @State private var secretID = ""
    @State private var secretKey = ""
    @State private var hasKeys = false
    @State private var institutions: [Institution] = []
    @State private var selectedInstitutionID: String?
    @State private var linkURL: IdentifiableURL?
    @State private var isWorking = false
    @State private var syncSummary: String?

    private var client: GoCardlessClient { GoCardlessClient(secrets: keychain) }

    var body: some View {
        Form {
            keysSection
            if hasKeys {
                statusSection
                if !currentAccounts.isEmpty { accountsSection }
                actionsSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle("bank.settings.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $linkURL) { item in
            SafariSheet(url: item.url)
                .ignoresSafeArea()
        }
        .onAppear(perform: bootstrap)
        .task(id: hasKeys) { if hasKeys { await loadInstitutions() } }
    }

    // MARK: Sections

    private var keysSection: some View {
        Section {
            if hasKeys {
                Label("bank.keys.stored", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Palette.ink)
                    .listRowBackground(Palette.surface)
            } else {
                SecureField("bank.keys.secretID", text: $secretID)
                    .textContentType(.password)
                    .accessibilityIdentifier("bankLink.secretID")
                    .listRowBackground(Palette.surface)
                SecureField("bank.keys.secretKey", text: $secretKey)
                    .textContentType(.password)
                    .accessibilityIdentifier("bankLink.secretKey")
                    .listRowBackground(Palette.surface)
                Button("bank.keys.save") { saveKeys() }
                    .disabled(secretID.isEmpty || secretKey.isEmpty)
                    .accessibilityIdentifier("bankLink.saveKeys")
                    .listRowBackground(Palette.surface)
            }
        } header: {
            Text("bank.keys.section").foregroundStyle(Palette.secondaryInk)
        } footer: {
            Text("bank.settings.footer").foregroundStyle(Palette.secondaryInk)
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("bank.status.title") {
                Text(statusText).foregroundStyle(Palette.secondaryInk)
            }
            .listRowBackground(Palette.surface)

            if store?.state.isLinked == true {
                LabeledContent("bank.sync.lastSync") {
                    Text(lastSyncText).foregroundStyle(Palette.secondaryInk)
                }
                .listRowBackground(Palette.surface)

                if bankSyncGate.lastHadError {
                    // Spec: "a plain error line" — same muted styling as every
                    // other secondary line on this screen (no ad-hoc color; the
                    // palette has no error/danger token and adding one is
                    // outside this lane's touched files).
                    Text("bank.sync.error")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                        .listRowBackground(Palette.surface)
                }
            }

            if store?.state.isLinked != true {
                Picker("bank.institution.select", selection: $selectedInstitutionID) {
                    Text("—").tag(String?.none)
                    ForEach(institutions) { inst in
                        Text(inst.name).tag(String?.some(inst.id))
                    }
                }
                .accessibilityIdentifier("bankLink.institutionPicker")
                .listRowBackground(Palette.surface)

                Button("bank.connect") { Task { await connect() } }
                    .disabled(selectedInstitutionID == nil || isWorking)
                    .accessibilityIdentifier("bankLink.connect")
                    .listRowBackground(Palette.surface)
            }

            if case .linkPending? = store?.state {
                Button("bank.checkLink") { Task { await store?.refreshRequisition() } }
                    .listRowBackground(Palette.surface)
            }
        } header: {
            Text("bank.status.title").foregroundStyle(Palette.secondaryInk)
        }
    }

    private var accountsSection: some View {
        Section {
            ForEach(currentAccounts, id: \.self) { account in
                Text(account)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Palette.surface)
            }
        } header: {
            Text("bank.accounts.title").foregroundStyle(Palette.secondaryInk)
        }
    }

    private var actionsSection: some View {
        Section {
            if store?.state.isLinked == true {
                Button("bank.sync.now") { Task { await syncNow() } }
                    .disabled(isWorking)
                    .accessibilityIdentifier("bankLink.syncNow")
                    .listRowBackground(Palette.surface)
            }
            if let syncSummary {
                Text(syncSummary)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Palette.surface)
            }
            Button(role: .destructive) { unlink() } label: {
                Label("bank.unlink", systemImage: "trash")
            }
            .accessibilityIdentifier("bankLink.unlink")
            .listRowBackground(Palette.surface)
        }
    }

    // MARK: Derived

    private var currentAccounts: [String] { store?.link?.accountIDs ?? [] }

    private var statusText: String {
        switch store?.state ?? .none {
        case .none: return String(localized: "bank.status.none")
        case .agreementCreated, .linkPending: return String(localized: "bank.status.pending")
        case .linked: return String(localized: "bank.status.linked")
        case .expired: return String(localized: "bank.status.expired")
        }
    }

    /// H1 (phase-A): the last successful sync (foreground or manual), read
    /// straight from `bankSyncGate` — never dated (recomputed on every body
    /// evaluation, so a fresh manual sync updates it immediately).
    private var lastSyncText: String {
        guard let date = bankSyncGate.lastSuccessAt else { return String(localized: "bank.sync.never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Actions

    private func bootstrap() {
        if store == nil {
            store = BankLinkStore(context: modelContext, client: client)
        }
        hasKeys = keychain.hasCredentials
    }

    private func saveKeys() {
        keychain.set(secretID.trimmingCharacters(in: .whitespacesAndNewlines), for: .secretID)
        keychain.set(secretKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .secretKey)
        secretID = ""
        secretKey = ""
        hasKeys = keychain.hasCredentials
    }

    private func loadInstitutions() async {
        institutions = await store?.loadInstitutions() ?? []
    }

    private func connect() async {
        guard let store, let id = selectedInstitutionID,
              let institution = institutions.first(where: { $0.id == id }) else { return }
        isWorking = true
        defer { isWorking = false }
        if let url = await store.beginLink(institution: institution) {
            linkURL = IdentifiableURL(url: url)
        }
    }

    private func syncNow() async {
        guard let store else { return }
        isWorking = true
        defer { isWorking = false }
        // Poll first in case the link just completed, then pull.
        await store.refreshRequisition()
        let accounts = store.link?.accountIDs ?? []
        let service = BankSyncService(modelContainer: modelContext.container)
        let outcome = await service.sync(accountIDs: accounts, client: client)
        // H1: manual sync bypasses `bankSyncGate.shouldSync` (this button always
        // runs) but still records the outcome so the status line above reflects
        // it — same bookkeeping the foreground path uses.
        bankSyncGate.recordOutcome(outcome)
        syncSummary = String(format: String(localized: "bank.sync.done %lld"), outcome.inserted)
    }

    private func unlink() {
        store?.unlink()
        hasKeys = false
        institutions = []
        selectedInstitutionID = nil
        syncSummary = nil
    }
}

// MARK: - Safari sheet

/// A minimal `SFSafariViewController` wrapper so the bank-auth URL opens in an
/// in-app browser sheet (not the external browser).
private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Identifiable wrapper so a produced link `URL` can drive `.sheet(item:)` without
/// a retroactive conformance on the Foundation type (house style — mirrors
/// `RaportHubView`'s export-file wrapper).
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
