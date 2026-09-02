import Foundation
import SwiftData
import Observation

/// P9 / v2.3 — the link lifecycle. The pure state machine (`BankLinkState` +
/// `BankLinkState.derive`) is source-and-network-free so it is fully unit-testable
/// (`BankLinkStoreTests`); `BankLinkStore` is the thin `@MainActor` orchestrator
/// that drives `EnableBankingClient` and persists the non-secret link metadata in
/// the `BankLink` `@Model`. NO secret ever touches this model — the worker base
/// URL and device token live ONLY in the Keychain (`KeychainStore`).
///
/// v2.3 replaces the old two-resource GoCardless model (agreement + requisition,
/// polled `LN`/`RJ`/`SU`/`EX` status codes) with Enable Banking's one-resource
/// flow: `POST /auth` → `POST /sessions {code}`. There is no agreement resource
/// and no status-code polling; `linked`/`expired` are derived from whether a
/// session exists, its `access.valid_until` window, and an explicit revocation
/// flag `BankSyncService` sets defensively on a 401/403 from `transactions`.

// MARK: - State machine

/// The coarse link lifecycle the UI reasons about. v2.3: FOUR states (no
/// `agreementCreated` — Enable Banking has no agreement resource; `POST /auth`
/// alone already puts the link in `linkPending`). `linked` carries the granted
/// account `uid`s.
enum BankLinkState: Equatable, Sendable {
    case none                       // nothing started
    case linkPending                // POST /auth done, awaiting bank auth + the callback code
    case linked(accountIDs: [String])
    case expired                    // consent window passed OR the session was revoked → re-link

    var isLinked: Bool { if case .linked = self { return true }; return false }
    var needsRelink: Bool { self == .expired }
    var accountIDs: [String] { if case .linked(let ids) = self { return ids }; return [] }
}

/// The persisted, secret-free snapshot the state machine reasons over.
struct BankLinkSnapshot: Equatable, Sendable {
    var authorizationID: String?
    var sessionID: String?
    var accountIDs: [String]
    var consentValidUntil: Date?
    var sessionRevoked: Bool

    init(
        authorizationID: String? = nil,
        sessionID: String? = nil,
        accountIDs: [String] = [],
        consentValidUntil: Date? = nil,
        sessionRevoked: Bool = false
    ) {
        self.authorizationID = authorizationID
        self.sessionID = sessionID
        self.accountIDs = accountIDs
        self.consentValidUntil = consentValidUntil
        self.sessionRevoked = sessionRevoked
    }
}

extension BankLinkState {
    /// The single, pure lifecycle derivation — every transition the tests assert.
    /// Order matters, same shape as the old GoCardless-era derive: an expired
    /// consent window (or an explicit revocation) always wins — a stale session
    /// with granted accounts never masks either — THEN progress.
    static func derive(from snap: BankLinkSnapshot, now: Date) -> BankLinkState {
        guard snap.authorizationID != nil || snap.sessionID != nil else { return .none }
        if snap.sessionRevoked { return .expired }
        if let validUntil = snap.consentValidUntil, validUntil <= now { return .expired }
        guard let sessionID = snap.sessionID, !sessionID.isEmpty else { return .linkPending }
        return snap.accountIDs.isEmpty ? .linkPending : .linked(accountIDs: snap.accountIDs)
    }

    /// Pure — how many whole days remain until `consentValidUntil`, ONLY when
    /// that is within 7 days (inclusive) from now; nil otherwise (too far out,
    /// already past — `derive` already reports that as `.expired`, not a
    /// "warning" — or no consent window at all). Phase 3 wires this into a
    /// "re-link soon" banner while the link is still `.linked`. Rounds UP
    /// (`ceil`) so a partial day still reads as "at least 1 day left" rather
    /// than a misleadingly reassuring "0".
    static func consentExpiryWarningDays(consentValidUntil: Date?, now: Date) -> Int? {
        guard let consentValidUntil else { return nil }
        let secondsRemaining = consentValidUntil.timeIntervalSince(now)
        guard secondsRemaining > 0 else { return nil }
        let daysRemaining = Int((secondsRemaining / 86_400).rounded(.up))
        guard daysRemaining <= 7 else { return nil }
        return daysRemaining
    }
}

// MARK: - Persisted model (secret-free)

/// The one additive `@Model` this feature adds — registered in `BaniModelContainer`
/// (appended after `Loan.self`, the additive tail). Holds ONLY non-secret link
/// metadata. There is at most one row (a single active bank link); the store
/// resolves "the" link as the newest row.
///
/// Additive-optional law: every field beyond `id` is optional or has a default, so
/// this is a lightweight SwiftData migration and existing stores are preserved.
/// v2.3 keeps every pre-v2.3 (GoCardless-era) stored property in place —
/// deleting one would be a schema change — even though the new state machine
/// above no longer reads most of them; three are REPURPOSED for the Enable
/// Banking flow (documented per-field below) rather than left fully dead, and
/// six new columns are appended (init parameter order matches the pre-v2.3
/// signature exactly, so `BackupDTOs.BankLinkDTO.makeModel()` keeps compiling
/// unchanged, picking up `nil`/`false` defaults for every new column).
@Model
final class BankLink {
    var id: UUID
    /// Pre-v2.3 (GoCardless institution id/name) — dead under v2.3: Enable
    /// Banking has no institution id, only `aspspName`/`aspspCountry` below.
    /// NEVER read or written by v2.3 code; kept only so an existing on-device
    /// row (or a restored pre-v2.3 backup) keeps decoding.
    var institutionID: String?
    var institutionName: String?
    /// Pre-v2.3 (GoCardless agreement id) — dead under v2.3: Enable Banking has
    /// no agreement resource. NEVER read or written by v2.3 code.
    var agreementID: String?
    /// v2.3: REPURPOSED to carry the `POST /auth` request's `state` UUID
    /// string — the CSRF-style correlation token the worker's `/callback`
    /// echoes back, matched by Phase 3's callback handler before it calls
    /// `completeLink(code:)`. Same "opaque string correlating a pending link"
    /// role the GoCardless requisition id played here pre-v2.3; NOT an Enable
    /// Banking identifier itself (that's `authorizationID` below). Cleared once
    /// the link completes (`completeLink(code:)`) — single-use.
    var requisitionID: String?
    /// Pre-v2.3 (the raw GoCardless requisition status code, `"LN"`/`"CR"`/…) —
    /// dead under v2.3: Enable Banking has no such status-code polling.
    var statusCode: String?
    /// Granted account `uid`s. v2.3: populated from `SessionResponse.accounts`
    /// (Enable Banking) once `POST /sessions` succeeds — same field, same role
    /// (the ids `BankSyncService.sync` iterates) it played pre-v2.3.
    var accountIDs: [String]
    /// Pre-v2.3 (the agreement's access-window end) — dead under v2.3:
    /// `consentValidUntil` below is the v2.3 equivalent (a distinct column, not
    /// a rename, per the additive-optional law).
    var agreementExpiresAt: Date?
    /// The pending auth `url` the user opens to authenticate (transient —
    /// cleared once linked). v2.3: populated from `AuthStartResponse.url`
    /// instead of a GoCardless requisition's `link` — same field, same role.
    var linkURL: String?
    /// Per-account last-successful-sync bookkeeping (account id → date), for the
    /// since-last-sync window.
    var lastSyncByAccount: [String: Date]
    var createdAt: Date

    // MARK: v2.3 additive columns

    /// `SessionResponse.sessionId` — set once `POST /sessions` succeeds
    /// (→ `.linked`); the id `refreshSession()`/`unlink()` GET/DELETE by.
    var sessionID: String?
    /// `AuthStartResponse.authorizationId` — set once `POST /auth` succeeds
    /// (→ `.linkPending`). Correlation/debug id; not required for any later call.
    var authorizationID: String?
    /// The ASPSP this link targets. Enable Banking identifies a bank by
    /// `name`+`country` (no institution id), replacing `institutionID`/`institutionName`.
    var aspspName: String?
    var aspspCountry: String?
    /// The consent's access window end (`SessionResponse.access.validUntil`,
    /// parsed) — `derive` reports `.expired` once `now` passes this.
    var consentValidUntil: Date?
    /// Set defensively (`BankSyncService`) on a 401/403 from `transactions`
    /// mid-life — Enable Banking's exact revocation status code is unverified,
    /// so both are treated as "the session was revoked" — `derive` reports
    /// `.expired` whenever this is `true`, regardless of `consentValidUntil`.
    var sessionRevoked: Bool?

    init(
        id: UUID = UUID(),
        institutionID: String? = nil,
        institutionName: String? = nil,
        agreementID: String? = nil,
        requisitionID: String? = nil,
        statusCode: String? = nil,
        accountIDs: [String] = [],
        agreementExpiresAt: Date? = nil,
        linkURL: String? = nil,
        lastSyncByAccount: [String: Date] = [:],
        createdAt: Date = .now,
        sessionID: String? = nil,
        authorizationID: String? = nil,
        aspspName: String? = nil,
        aspspCountry: String? = nil,
        consentValidUntil: Date? = nil,
        sessionRevoked: Bool? = nil
    ) {
        self.id = id
        self.institutionID = institutionID
        self.institutionName = institutionName
        self.agreementID = agreementID
        self.requisitionID = requisitionID
        self.statusCode = statusCode
        self.accountIDs = accountIDs
        self.agreementExpiresAt = agreementExpiresAt
        self.linkURL = linkURL
        self.lastSyncByAccount = lastSyncByAccount
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.authorizationID = authorizationID
        self.aspspName = aspspName
        self.aspspCountry = aspspCountry
        self.consentValidUntil = consentValidUntil
        self.sessionRevoked = sessionRevoked
    }

    /// The secret-free snapshot this row represents, for the pure state machine.
    var snapshot: BankLinkSnapshot {
        BankLinkSnapshot(
            authorizationID: authorizationID,
            sessionID: sessionID,
            accountIDs: accountIDs,
            consentValidUntil: consentValidUntil,
            sessionRevoked: sessionRevoked ?? false
        )
    }
}

// MARK: - Orchestrator

/// The `@MainActor` façade the `BankLinkView` binds to: it reads/writes the single
/// `BankLink` row and drives the client through the v2.3 auth/session lifecycle.
/// Kept deliberately thin — all lifecycle *logic* is the pure `BankLinkState.derive`
/// above, which is what the tests exercise (the network methods are a device
/// checklist item, per the CI-has-no-network rule).
@MainActor
@Observable
final class BankLinkStore {

    private let context: ModelContext
    private let client: EnableBankingClient

    init(context: ModelContext, client: EnableBankingClient) {
        self.context = context
        self.client = client
    }

    /// The single persisted link row (newest), or nil.
    var link: BankLink? {
        let all = (try? context.fetch(FetchDescriptor<BankLink>())) ?? []
        return all.sorted { $0.createdAt > $1.createdAt }.first
    }

    /// The current lifecycle state derived from the persisted row.
    var state: BankLinkState {
        guard let link else { return .none }
        return BankLinkState.derive(from: link.snapshot, now: Date())
    }

    /// Load the RO ASPSPs for the picker (silent [] on any failure).
    func loadASPSPs(country: String = "RO") async -> [ASPSP] {
        (try? await client.aspsps(country: country)) ?? []
    }

    /// Begin a link: `POST /auth`, persist the authorization + pending url +
    /// correlation state, and return the URL to open. nil on any failure
    /// (silent-degrade). Requests the ASPSP's own maximum consent window
    /// (`aspsp.maximumConsentValidity`, in seconds) — the widest window Enable
    /// Banking will grant for that bank.
    @discardableResult
    func beginLink(aspsp: ASPSP) async -> URL? {
        let authState = UUID()
        let validUntil = client.now().addingTimeInterval(TimeInterval(aspsp.maximumConsentValidity))
        do {
            let response = try await client.startAuth(
                aspspName: aspsp.name, country: aspsp.country, validUntil: validUntil, state: authState
            )
            upsert { row in
                row.authorizationID = response.authorizationId
                row.aspspName = aspsp.name
                row.aspspCountry = aspsp.country
                row.linkURL = response.url
                row.requisitionID = authState.uuidString
                row.sessionID = nil
                row.accountIDs = []
                row.consentValidUntil = nil
                row.sessionRevoked = false
            }
            return URL(string: response.url)
        } catch {
            return nil
        }
    }

    /// Exchange the callback's `code` for a session (→ `.linked`). Replaces the
    /// old poll-based `refreshRequisition()` — Enable Banking's flow is
    /// callback-driven, not polled. Returns the derived state after the
    /// attempt; unchanged (silent-degrade) on failure.
    @discardableResult
    func completeLink(code: String) async -> BankLinkState {
        do {
            let response = try await client.createSession(code: code)
            upsert { row in
                row.sessionID = response.sessionId
                row.accountIDs = response.accounts.map(\.uid)
                row.consentValidUntil = Self.parseValidUntil(response.access.validUntil)
                row.sessionRevoked = false
                row.linkURL = nil
                row.requisitionID = nil
            }
        } catch {
            // silent-degrade — the persisted row is left exactly as it was.
        }
        return state
    }

    /// Re-GET the session — the failure-retry path + expiry re-check (e.g. a UI
    /// "Refresh status" affordance, or a re-check before `syncNow()`).
    /// Best-effort: any failure leaves the persisted row untouched.
    @discardableResult
    func refreshSession() async -> BankLinkState {
        guard let sessionID = link?.sessionID else { return state }
        if let response = try? await client.session(id: sessionID) {
            upsert { row in
                row.accountIDs = response.accounts.map(\.uid)
                row.consentValidUntil = Self.parseValidUntil(response.access.validUntil)
            }
        }
        return state
    }

    /// Unlink: best-effort `DELETE /sessions/{id}` (never blocks the local
    /// wipe on its outcome), then delete the persisted link row AND wipe every
    /// Keychain secret (the wipe-keys contract). Leaves already-imported
    /// transactions untouched.
    func unlink() async {
        if let sessionID = link?.sessionID {
            _ = try? await client.deleteSession(id: sessionID)
        }
        for row in (try? context.fetch(FetchDescriptor<BankLink>())) ?? [] {
            context.delete(row)
        }
        try? context.save()
        client.secrets.wipeAll()
    }

    /// Merge an edit into the single link row (create if absent).
    private func upsert(_ mutate: (BankLink) -> Void) {
        let row = link ?? {
            let fresh = BankLink()
            context.insert(fresh)
            return fresh
        }()
        mutate(row)
        try? context.save()
    }

    /// Tolerant RFC3339 parse for `access.valid_until`. Enable Banking's own
    /// reference examples show BOTH a plain `Z`-suffixed form
    /// (`2019-08-24T14:15:22Z`) and a fractional-seconds offset form
    /// (`2020-12-01T12:00:00.000000+00:00`) — `ISO8601DateFormatter` needs
    /// `.withFractionalSeconds` explicitly for the latter, so try that first,
    /// then fall back to the plain form (`EnableBankingClient.rfc3339Formatter`).
    private static func parseValidUntil(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return EnableBankingClient.rfc3339Formatter.date(from: raw)
    }
}
