import XCTest
import SwiftData
@testable import Bani

/// v1.1 RUN 1 pure-logic coverage: direction migration + totals, People math,
/// document extraction (RO/EN, words+digits, date fallback), the amount scanner,
/// and the pre-seeded custom-category color distribution (H2).
final class DirectionPeopleExtractorTests: XCTestCase {

    // MARK: - Direction migration (A1)

    @MainActor
    func testExistingRowsMigrateToExpenseAndTotalsUnchanged() throws {
        let container = try ImportTestSupport.inMemoryContainer()
        let ctx = container.mainContext
        // "Legacy" rows created WITHOUT a direction — must default to expense.
        ctx.insert(Transaction(amount: 10, currency: .ron, context: .personal, descriptionText: "a", source: .manual))
        ctx.insert(Transaction(amount: 20, currency: .ron, context: .work, descriptionText: "b", source: .voice))
        try ctx.save()

        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertTrue(txs.allSatisfy { $0.direction == .expense }, "migrated rows are expenses")

        // Spending total is unchanged pre/post: expense-only sum == all-rows sum,
        // because every migrated row is an expense.
        let items = txs.map { SpendItem(amount: $0.amount, currency: $0.currency, date: $0.date) }
        XCTAssertEqual(FinancesAnalytics.combinedTotal(items, rate: nil), 30)
    }

    func testDirectionRawValuesStable() {
        XCTAssertEqual(TransactionDirection.expense.rawValue, "expense")
        XCTAssertEqual(TransactionDirection.income.rawValue, "income")
        XCTAssertEqual(TransactionDirection.neutral.rawValue, "neutral")
        XCTAssertEqual(TransactionDirection(rawValue: "expense"), .expense)
    }

    // MARK: - People math (B1)

    func testPeoplePaidReceivedNet() {
        let items = [
            PersonItem(counterparty: "Ana", amount: 100, currency: .ron, direction: .expense, date: .now),
            PersonItem(counterparty: "Ana", amount: 30, currency: .ron, direction: .income, date: .now),
            PersonItem(counterparty: "Ana", amount: 500, currency: .ron, direction: .neutral, date: .now),
            PersonItem(counterparty: "Bob", amount: 40, currency: .ron, direction: .income, date: .now),
        ]
        let s = PeopleAnalytics.summaries(items, rate: nil)
        let ana = try! XCTUnwrap(s.first { $0.counterparty == "Ana" })
        XCTAssertEqual(ana.paid, 100)
        XCTAssertEqual(ana.received, 30)
        XCTAssertEqual(ana.net, -70)                 // received − paid; neutral excluded
        XCTAssertEqual(ana.neutralCount, 1)
        XCTAssertEqual(ana.neutralTotal, 500)
        let bob = try! XCTUnwrap(s.first { $0.counterparty == "Bob" })
        XCTAssertEqual(bob.net, 40)
    }

    // MARK: - Amount scanner (E1 — words + digits, dedup)

    func testAmountScannerWordsDigitsDedup() {
        // The same amount stated in digits AND words dedups to one.
        let amounts = AmountScanner.scan("Chirie 1200 lei (una mie doua sute lei)")
        XCTAssertEqual(amounts.filter { $0.value == 1200 }.count, 1)

        XCTAssertEqual(AmountScanner.primary("Total: 1.200,50 lei")?.value, Decimal(string: "1200.50"))
        XCTAssertEqual(RomanianNumberWords.parse(["una", "mie", "doua", "sute"]), 1200)
        XCTAssertEqual(RomanianNumberWords.parse(["cincizeci", "si", "doi"]), 52)
        XCTAssertEqual(EnglishNumberWords.parse(["one", "thousand", "two", "hundred"]), 1200)
    }

    // MARK: - HeuristicExtractor (E1)

    func testHeuristicRomanianContract() {
        let text = """
        CONTRACT DE INCHIRIERE
        Locator: Popescu Ion
        Chirias: Ionescu Maria
        Chirie 1200 lei pe luna, incepand cu 1 ianuarie 2021.
        """
        let e = HeuristicExtractor().extractSync(text: text, fileName: "c.docx", importDate: Date())
        XCTAssertEqual(e.docType, .contract)
        XCTAssertEqual(e.amount, 1200)
        XCTAssertEqual(e.currency, .ron)
        XCTAssertNotNil(e.counterparty)
        XCTAssertFalse(e.dateWasFallback, "a stated date is not a fallback")
        XCTAssertFalse(e.summary.isEmpty)
    }

    func testHeuristicEnglishInvoice() {
        let text = """
        INVOICE #123
        Bill to: Acme Corp
        Total: 1,200.00 EUR
        Date: 05/03/2021
        """
        let e = HeuristicExtractor().extractSync(text: text, fileName: "i.pdf", importDate: Date())
        XCTAssertEqual(e.docType, .invoice)
        XCTAssertEqual(e.amount, Decimal(string: "1200.00"))
        XCTAssertEqual(e.currency, .eur)
    }

    func testHeuristicDateFallbackFlag() {
        let importDate = Date()
        let e = HeuristicExtractor().extractSync(text: "Chitanta pentru servicii. Suma 300 lei.", fileName: "r.pdf", importDate: importDate)
        XCTAssertEqual(e.docType, .receipt)
        XCTAssertEqual(e.amount, 300)
        XCTAssertTrue(e.dateWasFallback, "no date in the doc → flagged fallback")
        XCTAssertEqual(e.date, importDate, "fallback uses the import date")
    }

    // MARK: - Pre-seeded custom categories (H2 colors)

    func testSeededCustomsPalette() {
        XCTAssertEqual(SeededCustomCategory.allCases.count, 16)
        for c in SeededCustomCategory.allCases {
            XCTAssertEqual(c.colorIndex, c.order % 8, "H2 — color = order mod 8")
            XCTAssertTrue((0...7).contains(c.colorIndex))
            XCTAssertFalse(c.displayName.isEmpty)
            XCTAssertFalse(c.symbolName.isEmpty)
        }
        // OBSERVATII vocabulary resolves the family-A terms.
        XCTAssertEqual(ObservatiiVocabulary.match("materiale"), .materialeConstructii)
        XCTAssertEqual(ObservatiiVocabulary.match("notariat"), .notariatTaxe)
    }
}
