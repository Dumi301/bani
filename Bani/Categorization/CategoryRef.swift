import Foundation

/// The unified category identity used across analytics, search, grouping and the
/// pickers (C3). A transaction's category is EITHER a built-in preset OR a
/// user-defined custom category; `nil` (an absent ref) is "uncategorized". This
/// keeps the frozen preset enum intact while letting custom categories be full
/// first-class citizens everywhere a category is aggregated or filtered.
enum CategoryRef: Hashable, Sendable {
    case preset(TransactionCategory)
    case custom(UUID)

    /// Stable identity string — the preset raw value, or `custom:<uuid>` for a
    /// custom category. Used as a dictionary key / sort key / accessibility id.
    var id: String {
        switch self {
        case .preset(let category): return category.rawValue
        case .custom(let uuid): return "custom:\(uuid.uuidString)"
        }
    }

    var presetValue: TransactionCategory? {
        if case .preset(let category) = self { return category }
        return nil
    }

    var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }

    /// Deterministic sort key for an optional ref — uncategorized always sorts
    /// last (a tilde sorts after any letter/`custom:` prefix).
    static func sortKey(_ ref: CategoryRef?) -> String { ref?.id ?? "~uncategorized" }
}

extension Transaction {
    /// The unified category identity for this transaction. A custom assignment
    /// (`customCategoryID`, the C1 parallel field) wins; otherwise the preset
    /// enum; otherwise `nil`. The setter routes to the correct storage field so
    /// exactly one of the two is ever populated.
    var categoryRef: CategoryRef? {
        get {
            if let customCategoryID { return .custom(customCategoryID) }
            if let category { return .preset(category) }
            return nil
        }
        set {
            switch newValue {
            case .preset(let category):
                self.category = category
                self.customCategoryID = nil
            case .custom(let id):
                self.category = nil
                self.customCategoryID = id
            case nil:
                self.category = nil
                self.customCategoryID = nil
            }
        }
    }
}

extension CategoryRule {
    /// The category this rule maps its keyword to — a custom category when the
    /// (C3) `customCategoryID` is set, otherwise the preset enum.
    var ref: CategoryRef {
        if let customCategoryID { return .custom(customCategoryID) }
        return .preset(category)
    }
}
