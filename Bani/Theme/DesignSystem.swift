import SwiftUI

// MARK: - Cold Metal Banking — the one design system
//
// Single source of truth for the app's visual language ("cold metal banking"):
// the palette vocabulary, corner radii, motion spec, the brushed-metal surface
// treatment, and the user-selectable density scale. Colors themselves live in
// `Assets.xcassets` (every colorset has an Any + Dark appearance); the accessors
// below just give call sites one typed vocabulary. Raw `Color("Bani…")` refs
// remain valid and identical — the zero-hardcoded-colors discipline is absolute:
// every gradient here is built FROM those asset colors, never literal RGB.
//
// This file is the frozen seam. Surface views consume these tokens; they never
// redefine spacing, radii, springs, or metal treatments locally.

// MARK: - Palette

/// Typed handles onto the asset-catalog colorsets. Cold silver in light,
/// titanium black in dark; one cold electric green-teal accent reserved for
/// money, primary actions, and record/positive state.
enum Palette {
    static let canvas       = Color("BaniCanvas")        // app background
    static let surface      = Color("BaniSurface")       // brushed-steel plates
    static let ink          = Color("BaniInk")           // primary text
    static let secondaryInk = Color("BaniSecondaryInk")  // secondary text
    static let hairline     = Color("BaniHairline")      // borders / dividers
    static let accent       = Color("BaniAccent")        // money / actions / record
}

// MARK: - Radius

/// Tighter than paper-era radii — metal reads with crisper edges.
enum Radius {
    static let chip:    CGFloat = 8
    static let control: CGFloat = 10
    static let card:    CGFloat = 12
    static let button:  CGFloat = 16
    static let plate:   CGFloat = 20   // confirmation card / large rising sheets
}

// MARK: - Motion

/// One unified motion spec — quick, precise springs with minimal overshoot
/// (banking, not bouncy). Chart transitions, card slides, and taps all pull
/// from here so timing reads as one hand.
enum Motion {
    /// Primary UI spring (state changes, layout).
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.88)
    /// Tap / press feedback — a touch snappier.
    static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.90)
    /// Chart transitions (donut / bars / selection).
    static let chart  = Animation.spring(response: 0.38, dampingFraction: 0.90)
    /// Card slide (confirmation card, sheets).
    static let card   = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

// MARK: - Typography

/// Colder, more precise type than the paper era: default SF (no `.rounded`)
/// everywhere, with monospaced digits reserved for money and timers. The
/// `.rounded` face is retired app-wide — metal wants the crisper letterforms.
enum Typography {
    /// The hero total on Finances — the single most polished number in the app.
    /// Never shrinks with density (it is size-fixed, only Dynamic Type moves it).
    static let heroAmount = Font.system(size: 44, weight: .bold).monospacedDigit()

    /// A money amount at a given text style. Monospaced digits so columns of
    /// numbers align on the metal.
    static func amount(_ style: Font.TextStyle = .title3, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .default).weight(weight).monospacedDigit()
    }

    /// A monospaced timer / duration readout (recording timer, countdown).
    static func mono(_ style: Font.TextStyle) -> Font {
        .system(style, design: .default).monospacedDigit()
    }
}

// MARK: - Density (user setting)

/// The three layout densities (B1). Drives spacing, paddings, row heights, the
/// chart-card height, and secondary font sizing via environment injection. Hero
/// amounts and the 44 pt minimum tap target NEVER shrink.
enum DesignScale: String, CaseIterable, Identifiable, Sendable {
    case airy
    case balanced
    case dense

    var id: String { rawValue }

    /// Localized label for the Settings picker (ro + en).
    var label: String {
        switch self {
        case .airy:     String(localized: "density.airy")
        case .balanced: String(localized: "density.balanced")
        case .dense:    String(localized: "density.dense")
        }
    }

    var metrics: DesignMetrics {
        switch self {
        case .airy:
            DesignMetrics(screenPadding: 24, sectionSpacing: 26, cardPadding: 22,
                          rowVInset: 11, rowSpacing: 15, elementSpacing: 13,
                          chartCardHeight: 268, secondaryTextScale: 1.06)
        case .balanced:
            DesignMetrics(screenPadding: 20, sectionSpacing: 18, cardPadding: 16,
                          rowVInset: 6, rowSpacing: 10, elementSpacing: 9,
                          chartCardHeight: 232, secondaryTextScale: 1.00)
        case .dense:
            DesignMetrics(screenPadding: 16, sectionSpacing: 11, cardPadding: 12,
                          rowVInset: 3, rowSpacing: 6, elementSpacing: 6,
                          chartCardHeight: 200, secondaryTextScale: 0.92)
        }
    }
}

/// Resolved layout dimensions for a `DesignScale`. Every surface reads these
/// instead of scattering magic paddings. Values are monotonic across the three
/// levels (airy ≥ balanced ≥ dense) so the setting reads as a real dial.
struct DesignMetrics: Equatable, Sendable {
    var screenPadding: CGFloat       // horizontal screen inset
    var sectionSpacing: CGFloat      // between major blocks
    var cardPadding: CGFloat         // inside a metal card
    var rowVInset: CGFloat           // list / transaction row vertical inset
    var rowSpacing: CGFloat          // between stacked rows
    var elementSpacing: CGFloat      // small in-row gaps
    var chartCardHeight: CGFloat     // Finances chart card height
    var secondaryTextScale: CGFloat  // multiplier for secondary / caption sizing

    /// Invariant — the minimum tap target never shrinks with density (B1).
    static let minTapTarget: CGFloat = 44
}

private struct DesignScaleKey: EnvironmentKey {
    static let defaultValue: DesignScale = .balanced
}

extension EnvironmentValues {
    /// The active density. Injected once at the app root from
    /// `@AppStorage("designScale")`; every surface reads it live.
    var designScale: DesignScale {
        get { self[DesignScaleKey.self] }
        set { self[DesignScaleKey.self] = newValue }
    }

    /// Convenience: the resolved metrics for the active density.
    var metrics: DesignMetrics { designScale.metrics }
}

// MARK: - Brushed-metal surface

/// The brushed-metal plate treatment: the asset surface color, a subtle 3-stop
/// vertical luminance gradient (low delta — brushed, never mirror-chrome), a
/// hairline top-edge highlight, and a hairline border (strokes over shadows).
/// An optional minimal, cool-toned shadow lifts elevated plates.
struct MetalSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = Radius.card
    var elevated: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Low-delta luminance stops keep it brushed, not chromed.
        let topGlow: Double    = scheme == .dark ? 0.055 : 0.05
        let bottomShade: Double = scheme == .dark ? 0.050 : 0.035
        let edgeHighlight: Double = scheme == .dark ? 0.16 : 0.55
        return content
            .background {
                ZStack {
                    shape.fill(Palette.surface)
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(topGlow),     location: 0.0),
                                .init(color: .clear,                      location: 0.5),
                                .init(color: .black.opacity(bottomShade), location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    // Hairline top-edge glint — the brushed-metal highlight.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(edgeHighlight), .white.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    // Cool hairline border (over shadow, per the metal spec).
                    shape.strokeBorder(Palette.hairline, lineWidth: 1)
                }
            }
            .compositingGroup()
            .shadow(
                color: elevated ? Palette.ink.opacity(scheme == .dark ? 0.45 : 0.10) : .clear,
                radius: elevated ? 12 : 0, x: 0, y: elevated ? 6 : 0
            )
    }
}

extension View {
    /// Apply the brushed-metal plate treatment behind this content.
    func metalSurface(cornerRadius: CGFloat = Radius.card, elevated: Bool = false) -> some View {
        modifier(MetalSurface(cornerRadius: cornerRadius, elevated: elevated))
    }
}

/// A tappable brushed-metal plate (Log context buttons, thumb buttons, etc.).
/// Pressed state = a subtle darken (haptics stay with the call site). An
/// optional `accentWash` tints the plate with the money/action accent for
/// primary actions without becoming a flat accent block.
struct MetalPlateButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = Radius.button
    var accentWash: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .background {
                ZStack {
                    shape.fill(Palette.surface)
                    if accentWash {
                        shape.fill(Palette.accent.opacity(scheme == .dark ? 0.16 : 0.10))
                    }
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(scheme == .dark ? 0.06 : 0.055), location: 0.0),
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(scheme == .dark ? 0.05 : 0.04), location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    shape.strokeBorder(
                        (accentWash ? Palette.accent.opacity(0.55) : Palette.hairline),
                        lineWidth: 1
                    )
                    if configuration.isPressed {
                        shape.fill(Color.black.opacity(scheme == .dark ? 0.10 : 0.06))
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
