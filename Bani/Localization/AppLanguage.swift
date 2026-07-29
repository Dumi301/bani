import Foundation

/// The in-app language override (B2). `system` follows the device; the other two
/// pin the app to Romanian / English regardless of the system locale. Persisted
/// via `@AppStorage("appLanguage")`; applied live at the root through the
/// environment locale and, for cold launches / system dialogs, through
/// `AppleLanguages`.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case romanian
    case english

    var id: String { rawValue }

    /// BCP-47 code applied to `AppleLanguages` / `Locale`; `nil` for System.
    var localeCode: String? {
        switch self {
        case .system: nil
        case .romanian: "ro"
        case .english: "en"
        }
    }

    /// Row label. The two concrete languages are shown in their OWN name (the
    /// universal convention for a language picker); only "System" is localized.
    var label: String {
        switch self {
        case .system: String(localized: "language.system")
        case .romanian: "Română"
        case .english: "English"
        }
    }

    static func from(_ raw: String?) -> AppLanguage { AppLanguage(rawValue: raw ?? "") ?? .system }

    /// Maps a launch-argument / BCP-47 code to a case (test seam `-appLanguage`).
    static func fromCode(_ code: String) -> AppLanguage {
        switch code.lowercased() {
        case "ro": .romanian
        case "en": .english
        default: .system
        }
    }
}

/// Applies an `AppLanguage` to the process: writes `AppleLanguages` so a cold
/// launch and system-provided UI follow the choice. The live in-app switch is
/// driven separately by the root `.environment(\.locale, …)` override, so no
/// relaunch is required for the app's own strings.
enum LanguageController {
    static let storageKey = "appLanguage"

    static func apply(_ language: AppLanguage) {
        if let code = language.localeCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The locale to push into the environment for the chosen language — a fixed
    /// identifier for RO/EN, the auto-updating current locale for System.
    static func resolvedLocale(_ language: AppLanguage) -> Locale {
        if let code = language.localeCode { return Locale(identifier: code) }
        return Locale.autoupdatingCurrent
    }
}
