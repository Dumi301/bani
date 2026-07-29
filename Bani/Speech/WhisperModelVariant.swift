import Foundation

/// The user-selectable transcription model (B). `whisper-small` is the fast,
/// small default; `whisper-medium` is larger and slower but hears Romanian
/// noticeably better ("branșament" instead of "branchament"). Both variants can
/// coexist on disk — WhisperKit downloads each into its own per-variant folder —
/// so switching back and forth never re-downloads a model already fetched.
///
/// The active choice is persisted under `storageKey` in `@AppStorage`; sizes are
/// cited from the model cards, never measured by forcing a live download.
enum WhisperModelVariant: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium

    var id: String { rawValue }

    /// HF `whisperkit-coreml` repo variant name passed to WhisperKit.
    var hfVariant: String {
        switch self {
        case .small: "openai_whisper-small"
        case .medium: "openai_whisper-medium"
        }
    }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        }
    }

    /// Published on-disk size, cited from the model card.
    var approxSizeMB: Int {
        switch self {
        case .small: 485
        case .medium: 1500
        }
    }

    /// Human-readable size for the picker ("~485 MB" / "~1.5 GB").
    var sizeLabel: String {
        approxSizeMB >= 1000
            ? String(format: "~%.1f GB", Double(approxSizeMB) / 1000)
            : "~\(approxSizeMB) MB"
    }

    /// One-line trade-off shown under the picker.
    var blurb: String {
        switch self {
        case .small: "Faster · smaller download"
        case .medium: "Better Romanian · larger, slower"
        }
    }

    static let storageKey = "whisperModelVariant"

    /// The persisted active variant, defaulting to `.small`.
    static var active: WhisperModelVariant {
        WhisperModelVariant(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .small
    }
}
