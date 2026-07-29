import Foundation

/// The result of refining a raw Whisper transcript into one clean expense phrase.
/// `cleanText` is what the parser / categorizer / card / persistence consume;
/// `hadContent` is `false` when nothing meaningful survived cleaning (a recording
/// that was only non-speech artifacts or punctuation) — the pipeline routes that
/// to the existing no-speech error path, never a blank card.
struct RefinedTranscript: Equatable, Sendable {
    var cleanText: String
    var hadContent: Bool
}

/// The stage that sits BETWEEN transcription and parsing (A1). Raw Whisper output
/// on a real device is pause-fragmented ("cazare. mare.") and speckled with
/// non-speech annotations ("[music]", "(muzică)"); this cleans it so the parser,
/// categorizer, card, and persistence never see the noise.
///
/// - `RuleBasedRefiner` is the default everywhere (deterministic, offline, the
///   CI-exercised path).
/// - `FoundationModelsRefiner` is availability-gated and silently falls back to
///   `RuleBasedRefiner` on unavailability or any error.
///
/// `refine` is `async` to accommodate the Foundation Models implementation; the
/// rule-based implementation returns synchronously inside the async call.
/// Implementations MUST NOT throw and MUST NOT invent content — they only remove
/// noise and merge fragments, keeping every number and diacritic verbatim.
protocol TranscriptRefiner: Sendable {
    func refine(_ raw: String) async -> RefinedTranscript
}

/// Deterministic, offline transcript refiner (A1b). Default everywhere incl. CI.
///
/// Three pattern-based passes, none of which ever touches a number or a diacritic:
/// 1. strip bracketed / parenthesized non-speech annotations (RO + EN),
/// 2. merge fragment-splitting punctuation ("cazare. mare." → "cazare mare"),
///    while PRESERVING decimal separators ("12,50" stays "12,50"),
/// 3. collapse dictation-stutter repeats and runs of whitespace.
///
/// Pure value logic — `Sendable`, safe to call from any isolation context.
struct RuleBasedRefiner: TranscriptRefiner {

    init() {}

    func refine(_ raw: String) async -> RefinedTranscript {
        Self.refineSync(raw)
    }

    // MARK: - Pure refinement

    static func refineSync(_ raw: String) -> RefinedTranscript {
        var s = stripAnnotations(raw)
        s = mergePunctuation(s)
        s = collapseRepeats(s)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return RefinedTranscript(cleanText: trimmed, hadContent: !trimmed.isEmpty)
    }

    // MARK: - 1. Non-speech annotations

    /// `[ … ]` — Whisper emits `[music]`, `[blank audio]`, `[BLANK_AUDIO]`.
    private static let bracketRegex = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]")
    /// `( … )` — Whisper emits `(muzică)`, `(background noise)`, `(applause)`.
    private static let parenRegex = try! NSRegularExpression(pattern: "\\([^\\)]*\\)")

    /// Removes any bracketed / parenthesized span wholesale (pattern-based, not an
    /// exhaustive keyword list). Two passes so a nested / adjacent pair like
    /// "[a] (b)" is fully cleared. Diacritics inside an annotation go with it —
    /// the whole span is non-speech.
    static func stripAnnotations(_ text: String) -> String {
        var out = text
        for _ in 0..<2 {
            let before = out
            out = replacingMatches(bracketRegex, in: out)
            out = replacingMatches(parenRegex, in: out)
            if out == before { break }
        }
        return out
    }

    private static func replacingMatches(_ regex: NSRegularExpression, in text: String) -> String {
        guard !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    // MARK: - 2. Fragment-splitting punctuation

    /// Replaces sentence punctuation with a space so pause-fragments rejoin
    /// ("cazare. mare." → "cazare mare"), but keeps a `.` / `,` that sits BETWEEN
    /// two digits — those are decimal separators and the amount must survive
    /// verbatim ("12,50" / "12.50"). Letters (incl. diacritics), digits, `€`, and
    /// whitespace are preserved; every other symbol becomes a space.
    static func mergePunctuation(_ text: String) -> String {
        let chars = Array(text)
        var result = String()
        result.reserveCapacity(chars.count)
        for (index, character) in chars.enumerated() {
            if character.isLetter || character.isNumber || character.isWhitespace || character == "€" {
                result.append(character)
            } else if character == "." || character == "," {
                let previous = index > 0 ? chars[index - 1] : nil
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if let previous, let next, previous.isNumber, next.isNumber {
                    result.append(character)          // decimal separator — keep verbatim
                } else {
                    result.append(" ")                // fragment splitter — merge
                }
            } else {
                result.append(" ")                    // any other symbol splits fragments
            }
        }
        return result
    }

    // MARK: - 3. Repeats + whitespace

    /// Splits on whitespace, drops an immediately-repeated identical word (a
    /// dictation stutter like "taxi taxi" → "taxi"), and rejoins with single
    /// spaces. Tokens containing a digit are NEVER folded, so a repeated number
    /// ("20 20") is kept verbatim — never collapse a number.
    static func collapseRepeats(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        for token in tokens {
            if let last = out.last,
               !token.contains(where: \.isNumber),
               foldedEqual(last, token) {
                continue
            }
            out.append(token)
        }
        return out.joined(separator: " ")
    }

    /// Diacritic-fold + lowercase comparison (ro_RO), so "Cafea cafea" folds too —
    /// matching the identity `Categorizer.normalize` uses everywhere else.
    private static func foldedEqual(_ a: String, _ b: String) -> Bool {
        let locale = Locale(identifier: "ro_RO")
        return a.folding(options: .diacriticInsensitive, locale: locale).lowercased()
            == b.folding(options: .diacriticInsensitive, locale: locale).lowercased()
    }
}
