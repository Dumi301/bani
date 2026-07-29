import Foundation

/// One WhisperKit transcription segment, reduced to the four fields the quality
/// gate reads. A value type with no WhisperKit dependency, so the gate is
/// unit-testable with synthetic metadata (no live audio).
struct SpeechSegment: Equatable, Sendable {
    let text: String
    /// Whisper's probability that this segment is NOT speech (0…1). High → noise.
    let noSpeechProb: Float
    /// Mean token log-probability. Very negative → low-confidence decode.
    let avgLogprob: Float
    /// gzip compression ratio of the decoded text. High → repetitive hallucination.
    let compressionRatio: Float
}

/// A2 — drops transcription segments that Whisper's own metadata flags as
/// noise or hallucination, so background music / ambient audio never reaches a
/// saved entry. Pure value logic; the thresholds are named, conservative
/// defaults (the standard Whisper quality gates), never magic numbers.
enum SegmentGate {

    /// Above this no-speech probability the segment is treated as non-speech.
    static let maxNoSpeechProb: Float = 0.6
    /// Below this average log-probability the decode is too low-confidence to trust.
    static let minAvgLogprob: Float = -1.0
    /// Above this compression ratio the text is repetitive — a hallucination tell.
    static let maxCompressionRatio: Float = 2.4

    /// Whisper's well-known hallucination fillers, emitted from silence/music.
    /// Matched case-insensitively against the diacritic-folded segment text.
    static let junkPhrases: [String] = [
        "thanks for watching", "thank you for watching",
        "subscribe", "like and subscribe",
        "subtitrare", "subtitrari", "subtitles", "amara.org",
        "www.", ".com",
    ]

    struct Outcome: Equatable {
        let keptText: String
        let keptCount: Int
        let droppedCount: Int
        let totalCount: Int
        /// One compact line of the actual gate result for the Settings
        /// "Last voice session" forensics row.
        let diagnostics: String

        /// Every segment was flagged — the caller routes this to the existing
        /// "no speech detected" path.
        var allDropped: Bool { keptText.isEmpty && totalCount > 0 }
    }

    /// The reason a segment should be dropped, or `nil` to keep it. Canaries are
    /// checked first so a hallucinated filler is dropped regardless of its
    /// (often deceptively confident) probability scores.
    static func dropReason(_ s: SpeechSegment) -> String? {
        if isHallucinationCanary(s.text) { return "canary" }
        if s.noSpeechProb > maxNoSpeechProb { return String(format: "noSpeech %.2f", s.noSpeechProb) }
        if s.avgLogprob < minAvgLogprob { return String(format: "logprob %.2f", s.avgLogprob) }
        if s.compressionRatio > maxCompressionRatio { return String(format: "compRatio %.2f", s.compressionRatio) }
        return nil
    }

    /// Filters `segments`, keeping only the ones that pass every threshold and
    /// aren't hallucination canaries.
    static func filter(_ segments: [SpeechSegment]) -> Outcome {
        var kept: [String] = []
        var dropReasons: [String] = []
        for segment in segments {
            if let reason = dropReason(segment) {
                dropReasons.append(reason)
            } else {
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { kept.append(trimmed) }
            }
        }
        let keptText = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let diagnostics: String
        if segments.isEmpty {
            diagnostics = "no segment metadata"
        } else if dropReasons.isEmpty {
            diagnostics = "gate \(kept.count)/\(segments.count) kept"
        } else {
            diagnostics = "gate \(kept.count)/\(segments.count) kept · dropped: \(dropReasons.prefix(4).joined(separator: ", "))"
        }

        return Outcome(
            keptText: keptText,
            keptCount: kept.count,
            droppedCount: dropReasons.count,
            totalCount: segments.count,
            diagnostics: diagnostics
        )
    }

    /// A Whisper hallucination canary: empty, punctuation-only, a known junk
    /// filler, or a long run of one repeated character.
    static func isHallucinationCanary(_ text: String) -> Bool {
        let norm = Categorizer.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if norm.isEmpty { return true }
        // No letters or digits at all → pure punctuation ("...", "♪♪", "!!!").
        if !norm.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        for phrase in junkPhrases where norm.contains(phrase) { return true }
        if hasRepeatedRun(norm, minRun: 4) { return true }
        return false
    }

    /// True if `s` contains `minRun`+ consecutive identical non-space characters
    /// (repeated punctuation like "----" or "!!!!").
    private static func hasRepeatedRun(_ s: String, minRun: Int) -> Bool {
        var previous: Character?
        var run = 0
        for c in s {
            if c == previous {
                run += 1
                if run >= minRun, !c.isWhitespace { return true }
            } else {
                previous = c
                run = 1
            }
        }
        return false
    }
}
