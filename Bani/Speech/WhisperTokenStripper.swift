import Foundation

/// Removes WhisperKit special / decoder tokens like `<|startoftranscript|>`,
/// `<|ro|>`, `<|transcribe|>`, `<|0.00|>` from a transcript string so they can
/// NEVER reach parsing, display, categorization, or persistence (A1). The
/// primary defence is WhisperKit's own `skipSpecialTokens` decode option (set in
/// `WhisperService.transcribe`); this is the version-agnostic backstop that
/// guarantees the result is clean regardless of the installed WhisperKit build.
///
/// Pure and `Sendable`. Romanian diacritics (ș/ț/ă/î/â) are never touched — only
/// the `<|…|>` bracket patterns are removed — and any whitespace a removed token
/// leaves behind is collapsed so the result reads as clean speech.
enum WhisperTokenStripper {

    /// Matches a single `<|…|>` special-token bracket. Non-greedy and forbids a
    /// closing `>` inside so adjacent tokens (`<|a|><|b|>`) each match on their own.
    private static let tokenPattern = "<\\|[^>]*?\\|>"

    private static let tokenRegex = try! NSRegularExpression(pattern: tokenPattern)

    /// Strips every `<|…|>` token, then any stray unmatched bracket fragment, and
    /// collapses the leftover whitespace. Returns `""` if the input was only tokens.
    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let range = NSRange(text.startIndex..., in: text)
        var cleaned = tokenRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")

        // Defensive: a malformed token could leave a lone "<|" or "|>" behind.
        cleaned = cleaned.replacingOccurrences(of: "<|", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "|>", with: " ")

        return collapseWhitespace(cleaned)
    }

    /// True when `text` carries at least one special-token bracket — used by the
    /// one-shot cleanup migration to decide whether a stored row is dirty.
    static func containsToken(_ text: String) -> Bool {
        text.contains("<|") || text.contains("|>")
    }

    /// Splits on any run of whitespace and rejoins with single spaces, trimming
    /// the ends — so "  a  <token>  b " becomes "a b".
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
