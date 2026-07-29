import Foundation
import SwiftData

/// A remembered description correction (B3): when the user rewrites a card's
/// description, the pair {normalized raw transcript → corrected description} is
/// stored so a future transcript that normalizes equal reuses the correction
/// before parsing. A NEW, separate SwiftData entity — `Transaction` untouched.
///
/// Capped at `CorrectionMemoryStore.cap` (500) with LRU eviction keyed on
/// `updatedAt` (touched on every read + write).
@Model
final class CorrectionMemory {
    var id: UUID
    /// Normalized (lowercased + diacritic-folded, trimmed) raw transcript — the
    /// lookup key. See `Categorizer.normalize`.
    var normalizedRawTranscript: String
    var correctedDescription: String
    /// Last time this entry was written OR read — the LRU recency stamp.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        normalizedRawTranscript: String,
        correctedDescription: String,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.normalizedRawTranscript = normalizedRawTranscript
        self.correctedDescription = correctedDescription
        self.updatedAt = updatedAt
    }
}
