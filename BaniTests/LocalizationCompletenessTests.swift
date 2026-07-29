import XCTest
@testable import Bani

/// B5 — the Romanian catalog is complete (every key present in both languages,
/// no fallback leaks) and genuinely translated, not an English copy. Reads the
/// COMPILED `.strings` / `.stringsdict` from the app bundle (the test bundle is
/// hosted inside `Bani.app`, so `Bundle.main` is the app).
final class LocalizationCompletenessTests: XCTestCase {

    private func stringsDict(for lproj: String) -> [String: String]? {
        guard let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
              let bundle = Bundle(path: path),
              let stringsPath = bundle.path(forResource: "Localizable", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: String]
        else { return nil }
        return dict
    }

    /// Hard requirement: the app ships a Romanian localization with the critical
    /// user-facing keys translated.
    func testRomanianLocalizationExistsAndCoversCriticalKeys() throws {
        let ro = try XCTUnwrap(stringsDict(for: "ro"),
                               "the app must ship a Romanian localization (ro.lproj/Localizable.strings)")
        let critical = [
            // Core chrome + actions.
            "Save", "Delete", "Cancel", "Undo", "Edit", "Apply", "From", "To",
            "Finances", "Settings", "Transaction", "Understanding…",
            // Every enum-label display key (the leak-prone class: rendered via
            // Text(enum.label) so the enum itself must localize).
            "category.fuel", "category.groceries", "category.dining", "category.transport",
            "category.utilities", "category.shopping", "category.health",
            "category.entertainment", "category.other", "category.uncategorized",
            "context.work", "context.personal", "finances.segment.all",
            "appearance.system", "appearance.light", "appearance.dark",
            "timeframe.week", "timeframe.month", "timeframe.sixMonths", "timeframe.year", "timeframe.custom",
            "grouping.category", "grouping.month", "grouping.merchant",
            "chart.kind.category", "chart.kind.overTime", "chart.kind.trend",
            "chart.thisPeriod", "chart.previous", "chart.total",
            "model.small", "model.medium", "language.system",
            "decisions.trusted", "decisions.asking",
            // Feature surfaces.
            "categories.title", "category.new", "category.duplicate", "category.none",
            "settings.language", "confirm.noDescription", "finances.searchPrompt",
        ]
        let missing = critical.filter { ro[$0] == nil || (ro[$0]?.isEmpty ?? true) }
        XCTAssertTrue(missing.isEmpty, "Romanian is missing translations for: \(missing.sorted())")
    }

    /// Full parity when both compiled tables are available in this build layout.
    func testEnglishAndRomanianKeySetsMatch() throws {
        guard let en = stringsDict(for: "en"), let ro = stringsDict(for: "ro") else {
            throw XCTSkip("compiled en/ro .strings not both present in this build layout")
        }
        let missingInRo = Set(en.keys).subtracting(ro.keys)
        XCTAssertTrue(missingInRo.isEmpty, "keys missing a Romanian value: \(missingInRo.sorted())")
        let missingInEn = Set(ro.keys).subtracting(en.keys)
        XCTAssertTrue(missingInEn.isEmpty, "keys missing an English value: \(missingInEn.sorted())")
    }

    /// The Romanian values are actually Romanian (not the English fallback).
    func testRomanianIsTranslatedNotCopied() throws {
        let ro = try XCTUnwrap(stringsDict(for: "ro"))
        XCTAssertEqual(ro["category.fuel"], "Combustibil")
        XCTAssertEqual(ro["context.work"], "Muncă")
        XCTAssertEqual(ro["Save"], "Salvează")
        XCTAssertEqual(ro["Delete"], "Șterge")
        XCTAssertEqual(ro["Settings"], "Setări")
    }

    /// Plurals compile to `.stringsdict`. If present, it must exist for BOTH
    /// languages (asymmetry would leak an English plural); if the build embeds
    /// plurals differently, skip rather than falsely block.
    func testPluralStringsdictParity() throws {
        func hasStringsdict(_ lproj: String) -> Bool {
            let bundle = Bundle.main.path(forResource: lproj, ofType: "lproj").flatMap(Bundle.init(path:))
            return bundle?.path(forResource: "Localizable", ofType: "stringsdict") != nil
        }
        let en = hasStringsdict("en"), ro = hasStringsdict("ro")
        if !en && !ro { throw XCTSkip("plurals not compiled to a separate stringsdict in this build layout") }
        XCTAssertEqual(en, ro, "the plural stringsdict must exist for both languages, or neither")
    }
}
