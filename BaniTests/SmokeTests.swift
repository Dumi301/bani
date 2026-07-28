import XCTest
import SwiftData
@testable import Bani

/// Phase-0 smoke test: proves the frozen model + parsing contract compile and
/// round-trip through SwiftData. Workers add ParserTests / RateServiceTests /
/// etc. alongside this file (synced folder — no project edits needed).
final class SmokeTests: XCTestCase {

    func testTransactionModelPersistsInMemory() throws {
        let container = try ModelContainer(
            for: Transaction.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let tx = Transaction(
            amount: Decimal(string: "12.50")!,
            currency: .ron,
            context: .personal,
            descriptionText: "cafea",
            source: .manual
        )
        ctx.insert(tx)
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.amount, Decimal(string: "12.50"))
        XCTAssertEqual(all.first?.currency, .ron)
        XCTAssertEqual(all.first?.source, .manual)
    }

    func testParsedTransactionDefaultsToRON() {
        let parsed = ParsedTransaction(amount: Decimal(50), descriptionText: "benzină")
        XCTAssertEqual(parsed.currency, .ron)
        XCTAssertEqual(parsed.amount, Decimal(50))
        XCTAssertNil(parsed.merchant)
    }
}
