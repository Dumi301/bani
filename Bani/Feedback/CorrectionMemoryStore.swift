import Foundation
import SwiftData

/// The SwiftData-backed side of description-correction memory (B3). Stores the
/// pair {normalized raw transcript → corrected description} so a recurring
/// transcript reuses the fix before parsing. Capped at `cap` (500) with LRU
/// eviction on `updatedAt`, which is touched on every read AND write.
@MainActor
enum CorrectionMemoryStore {
    static let cap = 500

    /// Same normalize as everywhere else (fold + lowercase), then trimmed, so
    /// "Cafea la birou" and "cafea la birou" share one entry.
    private static func normalize(_ raw: String) -> String {
        Categorizer.normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remember (or update) a correction. No-op on an empty key or description.
    static func remember(rawTranscript: String, correctedDescription: String, in context: ModelContext) {
        let key = normalize(rawTranscript)
        let corrected = correctedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !corrected.isEmpty else { return }

        let descriptor = FetchDescriptor<CorrectionMemory>(
            predicate: #Predicate { $0.normalizedRawTranscript == key }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.correctedDescription = corrected
            existing.updatedAt = .now
        } else {
            context.insert(CorrectionMemory(normalizedRawTranscript: key, correctedDescription: corrected))
        }
        try? context.save()
        evictIfNeeded(in: context)
    }

    /// Look up a remembered correction for a raw transcript, touching its LRU
    /// recency so frequently-reused corrections survive eviction.
    static func lookup(rawTranscript: String, in context: ModelContext) -> String? {
        let key = normalize(rawTranscript)
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<CorrectionMemory>(
            predicate: #Predicate { $0.normalizedRawTranscript == key }
        )
        guard let hit = (try? context.fetch(descriptor))?.first else { return nil }
        hit.updatedAt = .now
        try? context.save()
        return hit.correctedDescription
    }

    static func count(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<CorrectionMemory>())) ?? 0
    }

    /// Evict the least-recently-used entries down to `cap`.
    private static func evictIfNeeded(in context: ModelContext) {
        let total = count(in: context)
        guard total > cap else { return }
        var descriptor = FetchDescriptor<CorrectionMemory>(
            sortBy: [SortDescriptor(\CorrectionMemory.updatedAt, order: .forward)]
        )
        descriptor.fetchLimit = total - cap
        let victims = (try? context.fetch(descriptor)) ?? []
        for victim in victims { context.delete(victim) }
        try? context.save()
    }
}
