import Foundation
import SwiftData
import Observation

/// P9 — the requisition lifecycle. The pure state machine (`BankLinkState` +
/// `BankLinkState.derive`) is source-and-network-free so it is fully unit-testable
/// (`BankLinkStoreTests`); `BankLinkStore` is the thin `@MainActor` orchestrator
/// that drives `GoCardlessClient` and persists the non-secret link metadata in the
/// `BankLink` `@Model`. NO secret ever touches this model — `secret_id`/`secret_key`
/// and the token live ONLY in the Keychain (`KeychainStore`).

// MARK: - Requisition status (tolerant)

/// The GoCardless requisition status codes, tolerant of anything unknown. Unknown
/// codes are treated as "still pending" so a feed quirk never trips a premature
/// expiry.
enum RequisitionStatus: String, Sendable, Equatable {
    case created = "CR"          // requisition created, awaiting the user
    case givingConsent = "GC"
    case undergoingAuth = "UA"
    case rejected = "RJ"
    case selectingAccounts = "SA"
    case grantingAccess = "GA"
    case linked = "LN"           // accounts granted
    case suspended = "SU"        // needs re-consent (90d idle)
    case expired = "EX"          // agreement expired
    case unknown = "??"

    init(code: String?) {
        self = code.flatMap { RequisitionStatus(rawValue: $0) } ?? .unknown
    }

    /// Whether this status means the link must be re-established (re-link).
    var needsRelink: Bool {
        switch self {
        case .rejected, .suspended, .expired: return true
        default: return false
        }
    }
}

// MARK: - State machine

/// The coarse link lifecycle the UI reasons about. `linked` carries the granted
/// account ids; `expired` covers agreement expiry AND rejected/suspended (all need
/// a re-link).
enum BankLinkState: Equatable, Sendable {
    case none                       // nothing started
    case agreementCreated           // agreement made, requisition not yet created
    case linkPending                // requisition created, awaiting bank auth
    case linked(accountIDs: [String])
    case expired                    // agreement expired / rejected / suspended → re-link

    var isLinked: Bool { if case .linked = self { return true }; return false }
    var needsRelink: Bool { self == .expired }
    var accountIDs: [String] { if case .linked(let ids) = self { return ids }; return [] }
}

/// The persisted, secret-free snapshot the state machine reasons over.
struct BankLinkSnapshot: Equatable, Sendable {
    var agreementID: String?
    var requisitionID: String?
    var status: RequisitionStatus?
    var accountIDs: [String]
    var agreementExpiresAt: Date?

    init(agreementID: String? = nil, requisitionID: String? = nil, status: RequisitionStatus? = nil, accountIDs: [String] = [], agreementExpiresAt: Date? = nil) {
        self.agreementID = agreementID
        self.requisitionID = requisitionID
        self.status = status
        self.accountIDs = accountIDs
        self.agreementExpiresAt = agreementExpiresAt
    }
}

extension BankLinkState {
    /// The single, pure lifecycle derivation — every transition the tests assert.
    /// Order matters: an expired agreement always wins (a stale `LN` status never
    /// masks an expired window), then explicit terminal statuses, then progress.
    static func derive(from snap: BankLinkSnapshot, now: Date) -> BankLinkState {
        guard snap.agreementID != nil else { return .none }
        if let expiresAt = snap.agreementExpiresAt, expiresAt <= now { return .expired }
        guard let status = snap.status else { return .agreementCreated }
        if status.needsRelink { return .expired }
        if status == .linked { return snap.accountIDs.isEmpty ? .linkPending : .linked(accountIDs: snap.accountIDs) }
        return .linkPending
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
@Model
final class BankLink {
    var id: UUID
    var institutionID: String?
    var institutionName: String?
    var agreementID: String?
    var requisitionID: String?
    /// The raw GoCardless status code (`"LN"`, `"CR"`, …) — decoded through the
    /// tolerant `RequisitionStatus`, never stored as the enum.
    var statusCode: String?
    /// Granted account ids, stored as a plain `[String]` (SwiftData supports a
    /// codable value array).
    var accountIDs: [String]
    var agreementExpiresAt: Date?
    /// The requisition `link` URL the user opens to authenticate (transient — cleared
    /// once linked).
    var linkURL: String?
    /// Per-account last-successful-sync bookkeeping (account id → date), for the
    /// since-last-sync window.
    var lastSyncByAccount: [String: Date]
    var createdAt: Date

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
        createdAt: Date = .now
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
    }

    /// The secret-free snapshot this row represents, for the pure state machine.
    var snapshot: BankLinkSnapshot {
        BankLinkSnapshot(
            agreementID: agreementID,
            requisitionID: requisitionID,
            status: statusCode.map { RequisitionStatus(code: $0) },
            accountIDs: accountIDs,
            agreementExpiresAt: agreementExpiresAt
        )
    }
}

// MARK: - Orchestrator

/// The `@MainActor` façade the `BankLinkView` binds to: it reads/writes the single
/// `BankLink` row and drives the client through the requisition lifecycle. Kept
/// deliberately thin — all lifecycle *logic* is the pure `BankLinkState.derive`
/// above, which is what the tests exercise (the network methods are a device
/// checklist item, per the CI-has-no-network rule).
@MainActor
@Observable
final class BankLinkStore {

    private let context: ModelContext
    private let client: GoCardlessClient

    /// The default redirect GoCardless bounces back to after bank auth. Any https
    /// URL is accepted by the API; the app polls the requisition on return rather
    /// than intercepting a custom scheme (AltStore-friendly — no URL-scheme
    /// registration needed).
    static let redirectURL = "https://bani.app/oauth/callback"

    init(context: ModelContext, client: GoCardlessClient) {
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

    /// Load the RO institutions for the picker (silent [] on any failure).
    func loadInstitutions() async -> [Institution] {
        (try? await client.institutions(country: "ro")) ?? []
    }

    /// Begin a link: create the agreement + requisition, persist them, and return
    /// the `link` URL to open. Returns nil on any failure (silent-degrade).
    func beginLink(institution: Institution) async -> URL? {
        do {
            let agreement = try await client.createAgreement(institutionID: institution.id)
            let reference = UUID().uuidString
            let requisition = try await client.createRequisition(
                institutionID: institution.id,
                agreementID: agreement.id,
                reference: reference,
                redirect: Self.redirectURL
            )
            let expiresAt = agreement.accessValidForDays.map { Calendar.current.date(byAdding: .day, value: $0, to: Date()) ?? Date() }
            upsert { row in
                row.institutionID = institution.id
                row.institutionName = institution.name
                row.agreementID = agreement.id
                row.requisitionID = requisition.id
                row.statusCode = requisition.status
                row.accountIDs = requisition.accounts ?? []
                row.agreementExpiresAt = expiresAt
                row.linkURL = requisition.link
            }
            return requisition.link.flatMap { URL(string: $0) }
        } catch {
            return nil
        }
    }

    /// Poll the requisition and persist the new status/accounts. Returns the derived
    /// state after refresh.
    @discardableResult
    func refreshRequisition() async -> BankLinkState {
        guard let requisitionID = link?.requisitionID else { return state }
        if let requisition = try? await client.requisition(id: requisitionID) {
            upsert { row in
                row.statusCode = requisition.status
                if let accounts = requisition.accounts { row.accountIDs = accounts }
                if requisition.status == RequisitionStatus.linked.rawValue { row.linkURL = nil }
            }
        }
        return state
    }

    /// Unlink: delete the persisted link AND wipe every Keychain secret (the
    /// wipe-keys contract). Leaves already-imported transactions untouched.
    func unlink() {
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
}
