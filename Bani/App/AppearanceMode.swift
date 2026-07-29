import SwiftUI

/// User-selectable appearance override. Persisted via `@AppStorage("appearanceMode")`
/// and applied at the root via `.preferredColorScheme`. Phase-0 FROZEN.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "appearance.system")
        case .light: String(localized: "appearance.light")
        case .dark: String(localized: "appearance.dark")
        }
    }

    /// `nil` follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
