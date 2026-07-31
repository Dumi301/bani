import Foundation

/// A2 — the refiner-path script guard. On a real device, a Romanian recording
/// that Whisper misdetects as a Slavic language comes back transcribed in
/// Cyrillic. Even with detection constrained to {ro, en} (A1), this is the
/// last-line defense: if the refined transcript is dominated by a non-Latin
/// script, treat it as "no speech" rather than saving Cyrillic garbage — the
/// voice pipeline then routes to the existing no-speech error path.
///
/// Pure value logic — `Sendable`, applied to every refiner's output in
/// `runVoicePipeline`, and unit-tested directly.
enum ScriptGuard {

    /// `true` when the text contains letters AND strictly more of them belong to
    /// a non-Latin script than to Latin. Romanian diacritics (ă, â, î, ș, ț) are
    /// Latin, so genuine Romanian is never flagged; a Cyrillic (or Greek, etc.)
    /// mistranscription is.
    static func isDominatedByNonLatin(_ text: String) -> Bool {
        var latin = 0
        var nonLatin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isLatinLetter(scalar) { latin += 1 } else { nonLatin += 1 }
        }
        return nonLatin > 0 && nonLatin > latin
    }

    /// Applies the guard to a refined transcript: forces `hadContent = false`
    /// when the cleaned text is dominated by a non-Latin script, leaving the text
    /// itself untouched (so the "Last voice session" row still shows what was
    /// heard). A no-op for ordinary Latin (Romanian/English) transcripts.
    static func apply(_ refined: RefinedTranscript) -> RefinedTranscript {
        guard isDominatedByNonLatin(refined.cleanText) else { return refined }
        return RefinedTranscript(cleanText: refined.cleanText, hadContent: false)
    }

    /// Latin letters across the blocks that hold every Romanian/English glyph:
    /// Basic Latin (A–Z, a–z), Latin-1 Supplement + Latin Extended-A/B
    /// (0x00C0…0x024F — covers ă â î ș ț, and the cedilla variants ş ţ), and
    /// Latin Extended Additional (0x1E00…0x1EFF). Everything else alphabetic
    /// (Cyrillic 0x0400…0x04FF, Greek, …) counts as non-Latin.
    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x41...0x5A).contains(v)
            || (0x61...0x7A).contains(v)
            || (0x00C0...0x024F).contains(v)
            || (0x1E00...0x1EFF).contains(v)
    }
}
