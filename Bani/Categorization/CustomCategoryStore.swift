import Foundation
import SwiftData

/// The SwiftData-backed side of custom categories (C2/C4): create, rename/
/// re-style, duplicate detection, and delete-with-reassignment. Mirrors
/// `CategoryRuleStore` — pure query/mutation bridging, no view state. Optional
/// `customCategoryID` equality is filtered in memory (matching the store's style
/// for enum/optional columns `#Predicate` cannot reliably translate).
@MainActor
enum CustomCategoryStore {

    // MARK: - Reading

    static func all(in context: ModelContext) -> [CustomCategory] {
        let descriptor = FetchDescriptor<CustomCategory>(sortBy: [SortDescriptor(\CustomCategory.createdAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func category(id: UUID, in context: ModelContext) -> CustomCategory? {
        all(in: context).first { $0.id == id }
    }

    /// Normalized (fold + lowercase + trim) form used for duplicate detection and
    /// name search — same folding the categorizer/search use.
    static func normalized(_ name: String) -> String {
        Categorizer.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether `name` (normalized) already names a custom category, optionally
    /// excluding one id (so a rename to its own current name is allowed).
    static func isDuplicate(name: String, excluding id: UUID? = nil, in context: ModelContext) -> Bool {
        let target = normalized(name)
        guard !target.isEmpty else { return false }
        return all(in: context).contains { $0.id != id && normalized($0.name) == target }
    }

    /// Transactions currently assigned to a custom category (C4 reassignment count).
    static func transactionCount(for id: UUID, in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        return all.filter { $0.customCategoryID == id }.count
    }

    // MARK: - Writing

    /// Creates a custom category when the name is non-empty and unique
    /// (normalized-insensitive, C2). Returns the created category, or `nil` when
    /// rejected — the caller surfaces the inline duplicate error.
    @discardableResult
    static func create(name: String, symbolName: String, colorIndex: Int, in context: ModelContext) -> CustomCategory? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isDuplicate(name: clean, in: context) else { return nil }
        let category = CustomCategory(name: clean, symbolName: symbolName, colorIndex: colorIndex)
        context.insert(category)
        try? context.save()
        return category
    }

    /// Renames / re-symbols / re-colors a custom category (C4). Rejects an
    /// empty or duplicate name (excluding itself). Returns whether it applied.
    @discardableResult
    static func update(_ category: CustomCategory, name: String, symbolName: String, colorIndex: Int, in context: ModelContext) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isDuplicate(name: clean, excluding: category.id, in: context) else { return false }
        category.name = clean
        category.symbolName = symbolName
        category.colorIndex = colorIndex
        try? context.save()
        return true
    }

    /// Delete WITH reassignment (C4): move every transaction AND every learned
    /// rule off `category` onto `target` (a preset or another custom), then delete
    /// it — never orphaning data, never silently deleting.
    static func delete(_ category: CustomCategory, reassignTo target: CategoryRef, in context: ModelContext) {
        let id = category.id

        // Move assigned transactions onto the target category.
        let allTx = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        for tx in allTx where tx.customCategoryID == id {
            tx.categoryRef = target
        }

        // Move learned rules that pointed at this custom category so the learning
        // keeps working under the new target.
        let allRules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        for rule in allRules where rule.customCategoryID == id {
            switch target {
            case .preset(let preset):
                rule.category = preset
                rule.customCategoryID = nil
            case .custom(let newID):
                rule.category = .other
                rule.customCategoryID = newID
            }
            rule.updatedAt = .now
        }

        context.delete(category)
        try? context.save()
    }
}
