import Foundation
import SwiftData

// MARK: - Person kind

/// Loosely categorizes a registered `Person` (v1.3 "People registry"). Stored
/// as its `String` rawValue via `Person.kindRaw` — the same additive-safe
/// discipline as `LoanKind` / `ScheduledDirection`: adding a case later only
/// widens the valid set, never rewrites stored rows. No UI surfaces this yet
/// (the registry ships with autocomplete + receivables first); the field is
/// ready for a future kind picker.
enum PersonKind: String, Codable, CaseIterable, Hashable, Sendable {
    case client
    case vendor
    case lender
    case other
}

// MARK: - SwiftData model

/// v1.3 "People registry" — formalizes the free-text `counterparty` strings
/// already scattered across `Transaction` / `ScheduledItem` into an optional,
/// go-forward registry (VISION §2 Position: "Owed people + sum — they owe ME").
///
/// Deliberately NOT a foreign key: every counterparty field STAYS a plain
/// `String`, matched to a `Person` only by normalized name (`PersonStore`), so
/// existing/historical rows are never rewritten and a typo'd or one-off
/// counterparty never requires a `Person` to exist. Registered ONLY by an
/// explicit "add to people" tap (see `PersonCounterpartyField`) — never
/// automatically from logging a transaction.
///
/// A NEW, separate entity — its own fields MAY be non-optional (no
/// pre-existing rows to decode NULL from), mirroring `Project` / `Loan`
/// (proven in `PersonMigrationTests`). Registered in
/// `BaniModelContainer.schema` AFTER `Project.self`.
@Model
final class Person {
    var id: UUID
    var name: String
    /// Diacritic-folded + lowercased `name` via `Categorizer.normalize` — the
    /// SAME convention every other free-text match in this app uses (parser,
    /// categorizer, search, counterparty grouping). Stored (not recomputed on
    /// every lookup) and kept in sync by `PersonStore` whenever `name` changes.
    var normalizedName: String
    /// `String`-raw backing for `PersonKind` — additive, optional.
    var kindRaw: String?
    var notes: String?
    /// v0.4 — trade / role ("electrician", "zidar"), matched by smart search
    /// alongside the name so "electricianul" finds the person. Optional +
    /// additive (this entity has live rows).
    var roleRaw: String?
    var createdAt: Date
    /// v0.4 — last local write, stamped by `SyncStamp` just before every save
    /// (nil = legacy row, read as `createdAt`). Optional + additive — the v0.5
    /// shared vault merges on it (last write wins).
    var updatedAt: Date?

    /// Non-optional-style computed accessor over the optional raw backing,
    /// mirroring `ScheduledItem.recurrence` / `Loan.kind`.
    var kind: PersonKind? {
        get { kindRaw.flatMap(PersonKind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        normalizedName: String,
        kind: PersonKind? = nil,
        notes: String? = nil,
        createdAt: Date = .now,
        role: String? = nil
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.kindRaw = kind?.rawValue
        self.notes = notes
        self.createdAt = createdAt
        self.roleRaw = role
    }
}

// MARK: - Snapshot

/// A value-type snapshot of one `Person`, mirroring `ProjectSnapshot` /
/// `ScheduledItemSnapshot` — views and pure logic work without a live
/// `ModelContext`.
struct PersonSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let normalizedName: String
    let kind: PersonKind?
    let notes: String?
    let createdAt: Date
    /// v0.4 — defaulted so existing memberwise call sites keep compiling.
    var role: String? = nil
}

extension Person {
    var snapshot: PersonSnapshot {
        PersonSnapshot(
            id: id, name: name, normalizedName: normalizedName,
            kind: kind, notes: notes, createdAt: createdAt, role: roleRaw
        )
    }
}
