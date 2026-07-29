import SwiftUI

/// The fixed design vocabulary for custom categories (C1/C2): 8 pre-approved
/// semantic asset color pairs (Any + Dark, contrast-checked) and a curated grid
/// of ~24 SF Symbols. Kept small and pre-approved so a user-made category still
/// reads as part of the one warm, desaturated family — never a raw color picker.
enum CustomCategoryPalette {
    /// 8 asset colorsets, each with an Any + Dark appearance (`BaniCustom0…7`).
    static let colorNames: [String] = (0..<8).map { "BaniCustom\($0)" }
    static var count: Int { colorNames.count }

    /// Palette color name for a stored `colorIndex`, wrapped defensively so a
    /// stale/out-of-range index can never crash.
    static func colorName(_ index: Int) -> String {
        guard count > 0 else { return "BaniSecondaryInk" }
        let wrapped = ((index % count) + count) % count
        return colorNames[wrapped]
    }

    static func color(_ index: Int) -> Color { Color(colorName(index)) }

    /// Curated SF Symbols for the creation grid — filled where possible so they
    /// read at the small chip / donut sizes like the presets do.
    static let symbols: [String] = [
        "tag.fill", "star.fill", "heart.fill", "gift.fill",
        "pawprint.fill", "book.fill", "graduationcap.fill", "airplane",
        "car.fill", "tram.fill", "house.fill", "wrench.and.screwdriver.fill",
        "cross.case.fill", "pills.fill", "dumbbell.fill", "figure.run",
        "cup.and.saucer.fill", "birthday.cake.fill", "gamecontroller.fill", "music.note",
        "camera.fill", "leaf.fill", "creditcard.fill", "banknote.fill",
    ]

    static let defaultSymbol = "tag.fill"
    static let defaultColorIndex = 0
}
