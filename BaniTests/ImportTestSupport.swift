import Foundation
import SwiftData
import XCTest
@testable import Bani

/// Shared fixtures + helpers for the import test suite. Fixtures live in
/// `BaniTests/Fixtures/` (bundled via the synced test folder); each loader falls
/// back to an in-code copy so the suite stays green even if a CI toolchain does
/// not bundle the resource — the bundled file is still shipped and preferred.
enum ImportTestSupport {

    /// The bundled `.xlsx` fixture bytes, or a base64-embedded fallback of the
    /// same file (one styled serial-date column, RO headers, shared strings).
    static func sampleXLSX() -> Data {
        if let url = Bundle(for: BundleAnchor.self).url(forResource: "sample", withExtension: "xlsx"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return Data(base64Encoded: embeddedXLSXBase64)!
    }

    /// The bundled `.csv` fixture bytes, or an in-code copy.
    static func sampleCSV() -> Data {
        if let url = Bundle(for: BundleAnchor.self).url(forResource: "sample", withExtension: "csv"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return Data(embeddedCSV.utf8)
    }

    /// An in-memory container carrying the FULL v1.1 schema (proves ImportBatch +
    /// the two Transaction additions register migration-safely).
    @MainActor
    static func inMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Transaction.self, CategoryRule.self,
            DecisionRecord.self, ContextRule.self, CorrectionMemory.self,
            CustomCategory.self, ImportBatch.self,
            configurations: config
        )
    }

    private final class BundleAnchor {}

    static let embeddedCSV = """
    Data;Suma;Descriere;Categorie
    15.03.2024;1.234,56;"Lidl, Cluj";Alimente
    16.03.2024;25.000;Chirie;Utilitati
    17.03.2024;-50,00;Rambursare taxa;Altele
    18.03.2024;12,50;Cafea la Starbucks;Restaurant
    """

    /// Base64 of `BaniTests/Fixtures/sample.xlsx` (kept in sync with that file).
    static let embeddedXLSXBase64 = "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"
}
