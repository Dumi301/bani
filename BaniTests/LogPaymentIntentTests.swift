import XCTest
import SwiftData
@testable import Bani

/// Part A — the auto-log write path (`AutoLogWriter`, the shared core the
/// `LogPaymentIntent` and the Settings test row both call). Payload → a persisted
/// first-class `Transaction`: `Decimal` amount, categorizer applied, verbatim
/// `rawTranscript`, RON default + EUR mapping, and a garbage amount that fails
/// gracefully — NEVER a zero-amount save.
@MainActor
final class LogPaymentIntentTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        try ImportTestSupport.inMemoryContainer().mainContext
    }

    private func allTransactions(_ ctx: ModelContext) -> [Transaction] {
        (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? []
    }

    func testPayloadPersistsFirstClassTransaction() throws {
        let ctx = try makeContext()
        let payload = AutoLogPayload(amountText: "45,00", currencyCode: "RON",
                                     merchant: "MEGA IMAGE", cardName: "•••• 1234", origin: .intent)
        let tx = try AutoLogWriter.log(payload, in: ctx)

        XCTAssertEqual(tx.amount, Decimal(string: "45")!)
        XCTAssertEqual(tx.currency, .ron)
        XCTAssertEqual(tx.source, .autoLogged)
        XCTAssertEqual(tx.direction, .expense)
        XCTAssertEqual(tx.merchant, "MEGA IMAGE")
        XCTAssertEqual(tx.descriptionText, "MEGA IMAGE")
        XCTAssertNil(tx.counterparty)
        // rawTranscript is verbatim + origin-tagged (preserved for future search).
        let raw = try XCTUnwrap(tx.rawTranscript)
        XCTAssertTrue(raw.hasPrefix("[intent]"), "origin marker preserved: \(raw)")
        XCTAssertTrue(raw.contains("MEGA IMAGE"))
        XCTAssertTrue(raw.contains("45"))
        XCTAssertTrue(raw.contains("RON"))
        // Exactly one row persisted.
        XCTAssertEqual(allTransactions(ctx).count, 1)
    }

    func testCurrencyDefaultsToRON() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "10", currencyCode: nil, merchant: "X"), in: ctx)
        XCTAssertEqual(tx.currency, .ron)
    }

    func testEURMapping() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "10", currencyCode: "EUR", merchant: "X"), in: ctx)
        XCTAssertEqual(tx.currency, .eur)
        // An unknown code falls back to RON rather than inventing a currency.
        let tx2 = try AutoLogWriter.log(AutoLogPayload(amountText: "10", currencyCode: "ZZZ", merchant: "Y"), in: ctx)
        XCTAssertEqual(tx2.currency, .ron)
    }

    func testRomanianDecimalAndFloatDustAmounts() throws {
        let ctx = try makeContext()
        let a = try AutoLogWriter.log(AutoLogPayload(amountText: "1.234,56", merchant: "A"), in: ctx)
        XCTAssertEqual(a.amount, Decimal(string: "1234.56")!)
        // Float-dust tail is rounded to money by the shared AmountLexer.
        let b = try AutoLogWriter.log(AutoLogPayload(amountText: "34839.699999999997", merchant: "B"), in: ctx)
        XCTAssertEqual(b.amount, Decimal(string: "34839.70")!)
    }

    func testGarbageAmountThrowsAndSavesNothing() throws {
        let ctx = try makeContext()
        XCTAssertThrowsError(try AutoLogWriter.log(AutoLogPayload(amountText: "not a number", merchant: "X"), in: ctx)) { error in
            XCTAssertEqual(error as? AutoLogError, .unparseableAmount("not a number"))
        }
        XCTAssertEqual(allTransactions(ctx).count, 0, "a garbage amount must never persist a row")
    }

    func testZeroAmountNeverSaves() throws {
        let ctx = try makeContext()
        XCTAssertThrowsError(try AutoLogWriter.log(AutoLogPayload(amountText: "0", merchant: "X"), in: ctx))
        XCTAssertThrowsError(try AutoLogWriter.log(AutoLogPayload(amountText: "0,00", merchant: "X"), in: ctx))
        XCTAssertEqual(allTransactions(ctx).count, 0, "a zero amount must never persist a row")
    }

    func testImplausibleAmountThrows() throws {
        let ctx = try makeContext()
        XCTAssertThrowsError(try AutoLogWriter.log(AutoLogPayload(amountText: "999999999999", merchant: "X"), in: ctx))
        XCTAssertEqual(allTransactions(ctx).count, 0)
    }

    /// The categorizer is applied — a learned rule wins, exactly like the voice card.
    func testCategorizerApplied() throws {
        let ctx = try makeContext()
        CategoryRuleStore.learn(correctedCategory: .groceries, description: "lidl", in: ctx)
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "50", merchant: "Lidl Cluj"), in: ctx)
        XCTAssertEqual(tx.category, .groceries, "the learned rule for 'lidl' must categorize the auto-logged payment")
    }

    /// No rule → the guess is `.other` (never a nil/placeholder category).
    func testUnknownMerchantFallsBackToOther() throws {
        let ctx = try makeContext()
        let tx = try AutoLogWriter.log(AutoLogPayload(amountText: "50", merchant: "Zzq Unknown Merchant"), in: ctx)
        XCTAssertEqual(tx.category, .other)
    }
}
