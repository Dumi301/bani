import XCTest
@testable import Bani

/// Fixture oracle (G): each synthetic client-family fixture imports end-to-end
/// with zero interaction to the expected counts / amounts / directions / categories
/// / counterparties — INCLUDING forward-filled dates, comma dates, credit rows as
/// income, and multi-sheet single-pass. Every value is synthetic/aliased.
final class ClientFixtureOracleTests: XCTestCase {

    private final class Anchor {}

    private func fixture(_ name: String) throws -> RawDocument {
        guard let url = Bundle(for: Anchor.self).url(forResource: name, withExtension: "xlsx") else {
            throw XCTSkip("fixture \(name).xlsx not bundled in this build layout")
        }
        let data = try Data(contentsOf: url)
        return try XLSXReader.parseRaw(data: data, fileName: "\(name).xlsx")
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }
    private func draft(_ drafts: [DraftTransaction], desc: String) -> DraftTransaction? {
        drafts.first { $0.descriptionText == desc }
    }

    // MARK: - Family A — Investment Tracker

    func testFamilyA_oracle() throws {
        let doc = try fixture("client-logA")
        let sheet = try XCTUnwrap(doc.sheets.first)
        guard case .transactions(.a, let headerRow) = FamilyDetection.classify(sheet) else {
            return XCTFail("Family A not detected")
        }
        let out = FamilyParser.parse(sheet: sheet, family: .a, headerRow: headerRow)
        let drafts = out.drafts

        // 16 transaction rows; the TOTAL footer excluded.
        XCTAssertEqual(drafts.count, 16, "16 tx rows (TOTAL footer excluded)")
        XCTAssertFalse(drafts.contains { $0.amount == Decimal(string: "194360.28") }, "footer TOTAL excluded")
        XCTAssertTrue(drafts.allSatisfy { $0.direction == .expense }, "Family A rows are expenses")
        XCTAssertTrue(drafts.allSatisfy { $0.currency == .ron }, "Family A amounts are RON")

        // Sum of the imported rows (NOT the decoy footer total).
        let sum = drafts.reduce(Decimal(0)) { $0 + $1.amount }
        XCTAssertEqual(sum, Decimal(string: "194635.28"))

        // Forward-fill [bug #1]: a blank-date row inherits the row above's date.
        let achizitie = try XCTUnwrap(draft(drafts, desc: "achizitie"))
        let notariat = try XCTUnwrap(draft(drafts, desc: "notariat"))
        XCTAssertTrue(sameDay(achizitie.date, date(2021, 1, 12)))
        XCTAssertTrue(sameDay(notariat.date, achizitie.date), "blank date forward-filled")
        let cadastru = try XCTUnwrap(draft(drafts, desc: "cadastru"))
        let topo = try XCTUnwrap(draft(drafts, desc: "topo"))
        XCTAssertTrue(sameDay(topo.date, cadastru.date), "topo forward-filled from cadastru")

        // Comma date [bug #3]: "10,08,2024" parses.
        let lacat = try XCTUnwrap(draft(drafts, desc: "lacat"))
        XCTAssertTrue(sameDay(lacat.date, date(2024, 8, 10)))

        // Categories via the OBSERVATII vocabulary; 'comision' → AGENCY (Family A).
        XCTAssertEqual(achizitie.category, .seededCustom(.achizitie))
        XCTAssertEqual(notariat.category, .seededCustom(.notariatTaxe))
        XCTAssertEqual(cadastru.category, .seededCustom(.cadastruIntabulare))
        XCTAssertEqual(draft(drafts, desc: "materiale")?.category, .seededCustom(.materialeConstructii))
        XCTAssertEqual(draft(drafts, desc: "manopera")?.category, .seededCustom(.manopera))
        XCTAssertEqual(draft(drafts, desc: "comision")?.category, .seededCustom(.comisionAgentie))
    }

    // MARK: - Family B — Raiffeisen statement (credits import as income)

    func testFamilyB_oracle() throws {
        let doc = try fixture("client-logB")
        let sheet = try XCTUnwrap(doc.sheets.first)
        guard case .transactions(.b, let headerRow) = FamilyDetection.classify(sheet) else {
            return XCTFail("Family B not detected")
        }
        let drafts = FamilyParser.parse(sheet: sheet, family: .b, headerRow: headerRow).drafts

        XCTAssertEqual(drafts.count, 8)
        XCTAssertEqual(drafts.filter { $0.direction == .income }.count, 1, "one credit row → income [bug #4]")
        XCTAssertEqual(drafts.filter { $0.direction == .neutral }.count, 3, "cash moves → neutral")
        XCTAssertEqual(drafts.filter { $0.direction == .expense }.count, 4)

        // The credit row is the client's incoming money — amount + counterparty.
        let income = try XCTUnwrap(drafts.first { $0.direction == .income })
        XCTAssertEqual(income.amount, Decimal(string: "615.28"))
        XCTAssertEqual(income.counterparty, "PersoanaB")

        // Counterparties extracted from the Nume/Denumire column (B2).
        let parties = Set(drafts.compactMap(\.counterparty))
        XCTAssertTrue(parties.isSuperset(of: ["FirmaA", "PersoanaB", "FirmaC", "PersoanaD"]))

        // 'comision' → BANK FEE in the bank-statement family (the other half of the
        // comision split, C3): "COMISION ADMINISTRARE" is bank-ish context.
        let comision = try XCTUnwrap(draft(drafts, desc: "COMISION ADMINISTRARE"))
        XCTAssertEqual(comision.category, .seededCustom(.comisioaneBancare))
        XCTAssertEqual(comision.direction, .expense)
        XCTAssertEqual(comision.amount, Decimal(string: "6.9"))
    }

    // MARK: - Family C — Centralizator (mixed RON+EUR, H3) + multi-sheet skip

    func testFamilyC_oracle() throws {
        let doc = try fixture("client-reportC-expected")
        // Multi-sheet single pass: the ledger imports; the pivot + running-balance
        // sheets are recognized and skipped.
        var ledger: RawSheet?
        var skippedRoles: [SheetSkipReason] = []
        for sheet in doc.sheets {
            switch FamilyDetection.classify(sheet) {
            case .transactions(.c, _): ledger = sheet
            case .skipped(let reason): skippedRoles.append(reason)
            default: break
            }
        }
        let sheet = try XCTUnwrap(ledger, "CENTRALIZATOR GENERAL ledger detected")
        XCTAssertTrue(skippedRoles.contains(.pivotSummary), "pivot sheet skipped")
        XCTAssertTrue(skippedRoles.contains(.runningBalance), "running-balance sheet skipped")

        guard case .transactions(.c, let headerRow) = FamilyDetection.classify(sheet) else {
            return XCTFail("Family C header")
        }
        let drafts = FamilyParser.parse(sheet: sheet, family: .c, headerRow: headerRow).drafts

        XCTAssertEqual(drafts.count, 15)
        XCTAssertEqual(drafts.filter { $0.direction == .expense }.count, 6)
        XCTAssertEqual(drafts.filter { $0.direction == .income }.count, 4)
        XCTAssertEqual(drafts.filter { $0.direction == .neutral }.count, 5)

        // H3 — mixed currency: EUR rows import NATIVE EUR from the VALUTA columns.
        let eur = drafts.filter { $0.currency == .eur }
        XCTAssertEqual(eur.count, 2, "two EUR rows")
        XCTAssertTrue(eur.contains { $0.amount == 200 && $0.direction == .expense }, "EUR 200 expense (native, not CURS-converted)")
        let eurIncome = try XCTUnwrap(eur.first { $0.direction == .income })
        XCTAssertEqual(eurIncome.amount, 500)
        XCTAssertEqual(eurIncome.counterparty, "PersoanaB")

        // Per-counterparty collapse (C4) — the person moves to the counterparty field.
        let parties = Set(drafts.compactMap(\.counterparty))
        XCTAssertTrue(parties.isSuperset(of: ["PersoanaA", "PersoanaB", "PersoanaC", "FirmaA"]))
        // Loans are neutral.
        XCTAssertTrue(drafts.contains { $0.counterparty == "FirmaA" && $0.direction == .neutral })

        // 'COMISION' CATEGORIE rows → BANK FEE (the other half of the comision
        // split, C3): Family C is a bank-statement ledger, so 'comision' with no
        // agency/real-estate context reads as a bank fee, not the agency commission
        // Family A resolves it to.
        let bankComision = drafts.filter { $0.category == .seededCustom(.comisioaneBancare) }
        XCTAssertEqual(bankComision.count, 2, "both plain COMISION rows resolve to the bank-fee custom")
        XCTAssertTrue(bankComision.allSatisfy { $0.direction == .expense })
    }

    // MARK: - Family D — monthly detail imports; yearly matrix skipped

    func testFamilyD_oracle() throws {
        let doc = try fixture("client-reportD-expected")
        var detail: RawSheet?
        var matrixSkipped = false
        for sheet in doc.sheets {
            switch FamilyDetection.classify(sheet) {
            case .transactions(.d, _): detail = sheet
            case .skipped(.budgetMatrix): matrixSkipped = true
            default: break
            }
        }
        XCTAssertTrue(matrixSkipped, "yearly matrix sheet skipped with a note")
        let sheet = try XCTUnwrap(detail, "monthly detail sheet imports")
        guard case .transactions(.d, let headerRow) = FamilyDetection.classify(sheet) else {
            return XCTFail("Family D detail header")
        }
        let drafts = FamilyParser.parse(sheet: sheet, family: .d, headerRow: headerRow).drafts

        XCTAssertEqual(drafts.count, 3)
        XCTAssertTrue(drafts.allSatisfy { $0.direction == .expense })
        XCTAssertTrue(drafts.allSatisfy { $0.context == .personal }, "H1 — Family D defaults to Personal")

        let utilitati = try XCTUnwrap(draft(drafts, desc: "factura curent"))
        XCTAssertEqual(utilitati.amount, 120)
        XCTAssertEqual(utilitati.category, .preset(.utilities))
        XCTAssertTrue(sameDay(utilitati.date, date(2018, 1, 3)))

        let combustibil = try XCTUnwrap(draft(drafts, desc: "plin motorina"))
        XCTAssertEqual(combustibil.amount, 200)
        XCTAssertEqual(combustibil.category, .preset(.fuel))
        XCTAssertTrue(sameDay(combustibil.date, utilitati.date), "forward-filled date")
    }

    // MARK: - Family E — excluded (no transactions)

    func testFamilyE_skipped() throws {
        let doc = try fixture("client-otherE")
        for sheet in doc.sheets {
            if case .transactions = FamilyDetection.classify(sheet) {
                XCTFail("Family E sheet '\(sheet.name ?? "")' must NOT be a transaction sheet")
            }
        }
    }

    // MARK: - Signatures don't false-positive on a generic table

    func testGenericCSV_notMisclassifiedAsFamily() throws {
        let csv = """
        Data,Suma,Descriere,Categorie
        15.03.2024,120,Benzina OMV,Combustibil
        16.03.2024,45.50,Cafea,Restaurant
        """
        let doc = try CSVParser.parseRaw(data: Data(csv.utf8), fileName: "g.csv")
        let sheet = try XCTUnwrap(doc.sheets.first)
        XCTAssertEqual(FamilyDetection.classify(sheet), .generic, "a plain table is generic, not a family")
    }
}
