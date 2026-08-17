import Foundation
import SwiftData

// MARK: - Project status

/// The lifecycle state of a `Project`. Persisted as its `String` rawValue, so —
/// like `TransactionSource` / `TransactionDirection` — adding a case later only
/// widens the valid set and never rewrites the strings existing rows hold.
enum ProjectStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case finished

    /// Localized display name (ro + en) — the stored `rawValue` is unchanged.
    var label: String {
        switch self {
        case .active:   String(localized: "project.status.active")
        case .finished: String(localized: "project.status.finished")
        }
    }
}

// MARK: - SwiftData model

/// v1.2a "Projects Core" — a business project the client uses as an *analytical
/// lens* over the single cash pot. Projects are NEVER wallets: money never moves
/// between them; a `Transaction` merely carries an optional `projectID` pointer
/// (resolved by id-lookup, mirroring the `customCategoryID` convention).
///
/// A NEW, separate SwiftData entity — the frozen `Transaction` model is untouched
/// except for the single sanctioned optional `projectID` field. Registering a new
/// entity is a lightweight, additive migration; existing rows are untouched
/// (proven in `ProjectMigrationTests`). New-entity fields may be non-optional
/// because there are no pre-existing rows to decode NULL from — the direction-crash
/// law governs additive columns on the *existing* `Transaction`, not a brand-new
/// table (same discipline as `CustomCategory` / `ImportBatch`).
///
/// - `colorIndex` indexes the fixed 8-swatch palette (`BaniCustom0…7`), the same
///   `mod 8` convention as `CustomCategory`.
/// - `sortOrder` gives the grid a stable, user-reorderable order.
/// - `archived` hides a project from pickers while keeping its transactions'
///   `projectID` intact (delete is disallowed once a project has transactions).
@Model
final class Project {
    var id: UUID
    var name: String
    var status: ProjectStatus
    var colorIndex: Int
    var sortOrder: Int
    var archived: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        status: ProjectStatus = .active,
        colorIndex: Int,
        sortOrder: Int = 0,
        archived: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.colorIndex = colorIndex
        self.sortOrder = sortOrder
        self.archived = archived
        self.createdAt = createdAt
    }
}

// MARK: - Snapshot

/// A value-type snapshot of one `Project`, so views and pure logic (cards,
/// pickers, `LiquidityCalculator`) can resolve a `projectID` to its display
/// attributes without a live `ModelContext` — mirrors `CustomCategorySnapshot`.
struct ProjectSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let status: ProjectStatus
    let colorIndex: Int
    let sortOrder: Int
    let archived: Bool
    let createdAt: Date
}

extension Project {
    var snapshot: ProjectSnapshot {
        ProjectSnapshot(
            id: id, name: name, status: status, colorIndex: colorIndex,
            sortOrder: sortOrder, archived: archived, createdAt: createdAt
        )
    }
}

/// A lookup from project id → snapshot, built once per render from a `@Query`
/// and threaded to the resolvers (card styling, chips, schedule grouping).
typealias ProjectLookup = [UUID: ProjectSnapshot]

extension Array where Element == Project {
    /// Builds the id → snapshot lookup for the resolver helpers.
    var lookup: ProjectLookup {
        var out: ProjectLookup = [:]
        for project in self { out[project.id] = project.snapshot }
        return out
    }
}
