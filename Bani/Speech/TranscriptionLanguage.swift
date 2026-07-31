import Foundation

/// The user-visible transcription-language escape hatch (A1). The app is
/// Romanian + English by design; `auto` lets WhisperKit decide between the two
/// (constrained detection, never a third language — see `LanguageConstraint`),
/// while `romanian` / `english` pin the decoder to one language for users whose
/// recordings are consistently misdetected. Persisted via
/// `@AppStorage(TranscriptionLanguage.storageKey)`; default `auto`.
enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case romanian
    case english

    var id: String { rawValue }

    /// The BCP-47 language code forced into WhisperKit's `DecodingOptions`.
    /// `nil` for `auto`, where `LanguageConstraint` picks ro/en at runtime.
    var forcedCode: String? {
        switch self {
        case .auto: nil
        case .romanian: "ro"
        case .english: "en"
        }
    }

    /// Picker label. The two concrete languages are shown in their OWN name (the
    /// universal convention for a language picker); only "Auto" is localized.
    var label: String {
        switch self {
        case .auto: String(localized: "transcription.auto")
        case .romanian: "Română"
        case .english: "English"
        }
    }

    static let storageKey = "transcriptionLanguage"

    /// The persisted choice, defaulting to `auto`.
    static var active: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto
    }
}

/// The RO/EN constraint applied to WhisperKit language detection (A1a). The app
/// only ever transcribes Romanian or English, so detection is never allowed to
/// leave that set: a noisy/short Romanian clip that the model would otherwise
/// argmax to a Slavic language (→ Russian "transcription") is pinned back to the
/// higher-probability of {ro, en}.
///
/// Pure value logic — `Sendable`, unit-tested directly (the model-dependent
/// `WhisperService.transcribe` path calls the SAME functions).
enum LanguageConstraint {
    /// The only languages the app supports.
    static let allowed = ["ro", "en"]
    /// The app's primary language — the floor when nothing else can be decided.
    static let primary = "ro"

    /// Auto mode: constrain the detector's per-language probabilities to
    /// {ro, en} and return the higher-probability code. WhisperKit's `langProbs`
    /// values are log-probabilities (higher = more likely; argmax is valid). If
    /// neither ro nor en is present (never expected — the map spans all
    /// languages), falls back to the primary language.
    static func choose(from langProbs: [String: Float]) -> String {
        let present = allowed.compactMap { code in langProbs[code].map { (code, $0) } }
        return present.max { $0.1 < $1.1 }?.0 ?? primary
    }

    /// The language code to force into `DecodingOptions` given the user's setting
    /// and (for `auto`) the detector output. A non-`auto` setting always wins;
    /// `auto` constrains detection to {ro, en}. This is the single decision point
    /// `WhisperService.transcribe` uses, so a test of this function is a test of
    /// the real path.
    static func resolve(setting: TranscriptionLanguage, langProbs: [String: Float]) -> String {
        setting.forcedCode ?? choose(from: langProbs)
    }
}
