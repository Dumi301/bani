import XCTest
@testable import Bani

/// Part B — the bank-notification extractor over synthetic (no client data)
/// Raiffeisen-shaped RO fixtures plus generic RO/EN patterns: amount (incl.
/// "1.234,56"), merchant/counterparty extraction, income detection, unparseable →
/// nil (edit-card path), implausible → capped to nil.
final class BankNotificationParserTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    func testExpenseWithCardTail() {
        let p = BankNotificationParser.parse("Plata 45,00 RON la MEGA IMAGE cu cardul ****1234")
        XCTAssertEqual(p.amount, dec("45"))
        XCTAssertEqual(p.currency, .ron)
        XCTAssertEqual(p.direction, .expense)
        XCTAssertEqual(p.merchant, "MEGA IMAGE")
    }

    func testRomanianGroupedAmount() {
        let p = BankNotificationParser.parse("Cumparare 34.839,70 RON la eMAG")
        XCTAssertEqual(p.amount, dec("34839.70"))
        XCTAssertEqual(p.currency, .ron)
        XCTAssertEqual(p.direction, .expense)
        XCTAssertEqual(p.merchant, "eMAG")
    }

    func testIncomingTransfer() {
        let p = BankNotificationParser.parse("Transfer primit 1.200,00 RON de la ION POPESCU")
        XCTAssertEqual(p.amount, dec("1200"))
        XCTAssertEqual(p.direction, .income)
        XCTAssertEqual(p.merchant, "ION POPESCU")
    }

    func testShortIncomingRO() {
        let p = BankNotificationParser.parse("Ai primit 250 RON de la Maria")
        XCTAssertEqual(p.amount, dec("250"))
        XCTAssertEqual(p.direction, .income)
        XCTAssertEqual(p.merchant, "Maria")
    }

    func testEnglishEuroExpense() {
        let p = BankNotificationParser.parse("Payment of 12.50 EUR at TESCO")
        XCTAssertEqual(p.amount, dec("12.50"))
        XCTAssertEqual(p.currency, .eur)
        XCTAssertEqual(p.direction, .expense)
        XCTAssertEqual(p.merchant, "TESCO")
    }

    func testImplausibleAmountCapsToNil() {
        let p = BankNotificationParser.parse("Plata 999999999999 RON la Ceva")
        XCTAssertNil(p.amount, "an implausible amount must not parse (edit-card path)")
    }

    func testUnparseableYieldsNilAmount() {
        let p = BankNotificationParser.parse("Notificare fara suma disponibila")
        XCTAssertNil(p.amount)
        XCTAssertNil(p.merchant)
        XCTAssertEqual(p.direction, .expense)
    }

    func testEmptyText() {
        XCTAssertEqual(BankNotificationParser.parse("   "), BankNotificationParse.empty)
    }
}
