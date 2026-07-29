import Foundation
import SwiftData

/// One-shot data cleanup (A2) run on the first launch of the version that fixes
/// the Whisper special-token leak. It:
///   1. strips `<|…|>` tokens from every stored `Transaction.descriptionText`
///      and `rawTranscript`, and
///   2. DELETES `learned` `CategoryRule`s whose keyword is a decoder-token
///      artifact (contains `<|`/`|>`, a token fragment like `startoftranscript`
///      / `transcribe`, or a bare language code such as `ro`).
/// Seed rules are never touched. The counts are logged to the Settings
/// "Last voice session" forensics row.
///
/// Guarded by a persisted flag so it runs exactly once; `run` (no guard) is
/// exposed so unit tests can drive it against dirty fixtures directly.
@MainActor
enum TokenCleanupMigration {

    /// Bump the suffix if the cleanup logic ever needs to re-run on installs that
    /// already migrated once.
    static let versionKey = "tokenCleanupMigration.v1.done"

    struct Summary: Equatable {
        var descriptionsCleaned: Int
        var transcriptsCleaned: Int
        var rulesDeleted: Int
        var didRun: Bool

        var changedAnything: Bool { descriptionsCleaned + transcriptsCleaned + rulesDeleted > 0 }

        /// Compact forensics line for the Settings diagnostics row.
        var forensicsLine: String {
            "cleanup: \(descriptionsCleaned) desc · \(transcriptsCleaned) transcript · \(rulesDeleted) junk rules"
        }
    }

    /// Runs the cleanup once per install. A no-op (with `didRun == false`) after
    /// the first successful run.
    @discardableResult
    static func runIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard) -> Summary {
        guard !defaults.bool(forKey: versionKey) else {
            return Summary(descriptionsCleaned: 0, transcriptsCleaned: 0, rulesDeleted: 0, didRun: false)
        }
        let summary = run(context)
        defaults.set(true, forKey: versionKey)
        // Only surface a forensics line when something was actually cleaned, so a
        // fresh install never overwrites its (empty) diagnostics row with "0/0/0".
        if summary.changedAnything {
            defaults.set(summary.forensicsLine, forKey: VoiceSessionLog.forensicsKey)
        }
        return summary
    }

    /// The cleanup itself, with NO version guard — exposed for tests.
    @discardableResult
    static func run(_ context: ModelContext) -> Summary {
        var descriptionsCleaned = 0
        var transcriptsCleaned = 0
        var rulesDeleted = 0

        // 1. Strip tokens from stored transactions.
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        for tx in transactions {
            if WhisperTokenStripper.containsToken(tx.descriptionText) {
                tx.descriptionText = WhisperTokenStripper.strip(tx.descriptionText)
                descriptionsCleaned += 1
            }
            if let raw = tx.rawTranscript, WhisperTokenStripper.containsToken(raw) {
                tx.rawTranscript = WhisperTokenStripper.strip(raw)
                transcriptsCleaned += 1
            }
        }

        // 2. Delete LEARNED rules whose keyword is a token artifact. Seeds untouched.
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        for rule in rules where rule.origin == .learned && isJunkKeyword(rule.keyword) {
            context.delete(rule)
            rulesDeleted += 1
        }

        try? context.save()
        return Summary(
            descriptionsCleaned: descriptionsCleaned,
            transcriptsCleaned: transcriptsCleaned,
            rulesDeleted: rulesDeleted,
            didRun: true
        )
    }

    // MARK: - Junk-keyword detection

    /// Whisper decoder-token fragments that must never have become learned keywords.
    static let tokenFragments: [String] = [
        "startoftranscript", "endoftext", "transcribe", "translate",
        "nospeech", "notimestamps", "startoflm", "startofprev",
    ]

    /// Bare language codes Whisper emits as `<|xx|>` tokens — junk only when they
    /// are the WHOLE keyword, so a real word that merely contains "ro" is safe.
    static let languageCodes: Set<String> = [
        "ro", "en", "fr", "de", "es", "it", "ru", "hu", "tr", "pt", "nl", "pl", "uk",
    ]

    static func isJunkKeyword(_ keyword: String) -> Bool {
        if keyword.contains("<|") || keyword.contains("|>") { return true }
        let norm = keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if languageCodes.contains(norm) { return true }
        for fragment in tokenFragments where norm.contains(fragment) { return true }
        return false
    }
}
