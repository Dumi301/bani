import SwiftUI
import SwiftData
import AuthenticationServices

/// P9 / v2.3 — the Settings surface for open-banking. Entirely gated behind this
/// screen: with no credentials entered, the rest of the app shows nothing
/// bank-related (the only always-visible affordance is the Settings row that
/// pushes here). The worker base URL + device token are entered here and written
/// straight to the Keychain (`KeychainStore`) — never rendered back, never stored
/// elsewhere.
///
/// v2.3 replaces the old GoCardless model (two secret keys, an in-app
/// `SFSafariViewController` requisition sheet, and status polling) with the Enable
/// Banking worker flow: a worker URL + device token, and an
/// `ASWebAuthenticationSession` consent hop (`WebAuthCoordinator`) whose
/// `bani://oauth/callback` return carries the `code` (+ a `state` we verify)
/// exchanged for a session via `store.completeLink(code:)`. Pull is manual
/// ("Sync now") here; the app-foreground opportunistic pull is wired by the root.
struct BankLinkView: View {
    @Environment(\.modelContext) private var modelContext

    private let keychain = KeychainStore()
    /// H1 (phase-A): stateless status/throttle wrapper shared with
    /// `BaniApp.syncBankIfNeeded` — read here to show the last-sync time + a
    /// plain error line, and updated after every manual "Sync now" too.
    private let bankSyncGate = BankSyncGate()

    @State private var store: BankLinkStore?
    @State private var workerURL = ""
    @State private var deviceToken = ""
    @State private var hasKeys = false
    @State private var aspsps: [ASPSP] = []
    @State private var selectedASPSPID: String?
    @State private var isWorking = false
    @State private var linkError = false
    @State private var syncSummary: String?

    private var client: EnableBankingClient { EnableBankingClient(secrets: keychain) }

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
        .onAppear(perform: bootstrap)
        .task(id: hasKeys) { if hasKeys { await loadASPSPs() } }
    }

    // MARK: Sections

    private var keysSection: some View {
        Section {
            if hasKeys {
                Label("bank.keys.stored", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Palette.ink)
                    .listRowBackground(Palette.surface)
            } else {
                TextField("bank.keys.workerURL", text: $workerURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("bankLink.workerURL")
                    .listRowBackground(Palette.surface)
                SecureField("bank.keys.deviceToken", text: $deviceToken)
                    .textContentType(.password)
                    .accessibilityIdentifier("bankLink.deviceToken")
                    .listRowBackground(Palette.surface)
                Button("bank.keys.save") { saveKeys() }
                    .disabled(workerURL.isEmpty || deviceToken.isEmpty)
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

                // Consent-expiry warning while still linked (1…7 days out). Once
                // the window actually passes, `state` is `.expired` and the
                // `bank.status.expired` status text above takes over instead.
                if let days = consentExpiryDays {
                    Text(String(format: String(localized: "bank.consent.expiresIn %lld"), days))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                        .listRowBackground(Palette.surface)
                }

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
                Picker("bank.institution.select", selection: $selectedASPSPID) {
                    Text("—").tag(String?.none)
                    ForEach(aspsps) { aspsp in
                        Text(aspsp.name).tag(String?.some(aspsp.id))
                    }
                }
                .accessibilityIdentifier("bankLink.institutionPicker")
                .listRowBackground(Palette.surface)

                Button("bank.connect") { Task { await connect() } }
                    .disabled(selectedASPSPID == nil || isWorking)
                    .accessibilityIdentifier("bankLink.connect")
                    .listRowBackground(Palette.surface)
            }

            // Demoted to a failure-retry affordance: only shown when a link is
            // stuck `.linkPending` (a crashed / backgrounded auth session). It
            // re-checks the session and, if still pending, resumes the auth from
            // the stored link URL (else re-begins from the picker selection).
            if case .linkPending? = store?.state {
                Button("bank.checkLink") { Task { await checkLink() } }
                    .disabled(isWorking)
                    .listRowBackground(Palette.surface)
            }

            if linkError {
                Text("bank.link.error")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
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
            Button(role: .destructive) { Task { await unlink() } } label: {
                Label("bank.unlink", systemImage: "trash")
            }
            .accessibilityIdentifier("bankLink.unlink")
            .listRowBackground(Palette.surface)
        }
    }

    // MARK: Derived

    private var currentAccounts: [String] { store?.link?.accountIDs ?? [] }

    /// The consent-expiry warning window (1…7 whole days) while still `.linked`;
    /// nil otherwise (too far out, already past — reported as `.expired`, not a
    /// warning — or no consent window at all). Pure delegation to the state
    /// machine so the "when to warn" rule lives in exactly one place.
    private var consentExpiryDays: Int? {
        BankLinkState.consentExpiryWarningDays(consentValidUntil: store?.link?.consentValidUntil, now: Date())
    }

    private var statusText: String {
        switch store?.state ?? .none {
        case .none: return String(localized: "bank.status.none")
        case .linkPending: return String(localized: "bank.status.pending")
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
        // Trim trailing slash(es) so the stored base URL composes cleanly with
        // the client's `base + path` request building (mirrors the client's own
        // `requireWorkerBaseURL` normalization).
        var url = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        keychain.set(url, for: .workerBaseURL)
        keychain.set(deviceToken.trimmingCharacters(in: .whitespacesAndNewlines), for: .deviceToken)
        workerURL = ""
        deviceToken = ""
        hasKeys = keychain.hasCredentials
    }

    private func loadASPSPs() async {
        aspsps = await store?.loadASPSPs() ?? []
    }

    private func connect() async {
        guard let store, let id = selectedASPSPID,
              let aspsp = aspsps.first(where: { $0.id == id }) else { return }
        isWorking = true
        linkError = false
        defer { isWorking = false }
        guard let url = await store.beginLink(aspsp: aspsp) else {
            linkError = true
            return
        }
        await runAuth(url: url)
    }

    /// Drive one `ASWebAuthenticationSession` round: open `url`, verify + parse
    /// the callback, exchange the `code` for a session. User-cancel resets
    /// silently (no error UI — the link stays `.linkPending`, recoverable via
    /// "check the link"); any other failure shows the plain error line.
    private func runAuth(url: URL) async {
        do {
            let callback = try await WebAuthCoordinator().authenticate(url: url)
            guard let code = Self.parseCallback(callback, expectedState: store?.link?.requisitionID) else {
                linkError = true
                return
            }
            await store?.completeLink(code: code)
        } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
            // User dismissed the sheet — not an error; leave the pending link be.
        } catch {
            linkError = true
        }
    }

    /// Failure-retry: re-GET the session and, if it is still pending, resume the
    /// stored auth URL (a crashed / backgrounded consent) or, absent one,
    /// re-begin from the current picker selection.
    private func checkLink() async {
        guard let store else { return }
        isWorking = true
        linkError = false
        defer { isWorking = false }
        if case .linkPending = await store.refreshSession() {
            if let urlString = store.link?.linkURL, let url = URL(string: urlString) {
                await runAuth(url: url)
            } else if let id = selectedASPSPID,
                      let aspsp = aspsps.first(where: { $0.id == id }),
                      let url = await store.beginLink(aspsp: aspsp) {
                await runAuth(url: url)
            }
        }
    }

    private func syncNow() async {
        guard let store else { return }
        isWorking = true
        defer { isWorking = false }
        // v2.3: no pre-poll — Enable Banking is callback-driven, not polled, so
        // the session is already current here; just pull.
        let accounts = store.link?.accountIDs ?? []
        let service = BankSyncService(modelContainer: modelContext.container)
        let outcome = await service.sync(accountIDs: accounts, client: client)
        // H1: manual sync bypasses `bankSyncGate.shouldSync` (this button always
        // runs) but still records the outcome so the status line above reflects
        // it — same bookkeeping the foreground path uses.
        bankSyncGate.recordOutcome(outcome)
        syncSummary = String(format: String(localized: "bank.sync.done %lld"), outcome.inserted)
    }

    private func unlink() async {
        await store?.unlink()
        hasKeys = false
        aspsps = []
        selectedASPSPID = nil
        syncSummary = nil
        linkError = false
    }

    /// Pull `code` from the `bani://oauth/callback?code=…&state=…` return, but
    /// ONLY when `state` matches the correlation token stored at `beginLink`
    /// (the CSRF guard) — a missing or mismatched `state`, or an absent `code`,
    /// is rejected (nil).
    private static func parseCallback(_ url: URL, expectedState: String?) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let state = items.first { $0.name == "state" }?.value
        guard let expectedState, let state, state == expectedState else { return nil }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }
}
