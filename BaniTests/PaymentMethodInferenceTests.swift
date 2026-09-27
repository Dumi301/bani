import XCTest
@testable import Bani

/// v0.3 — pure-logic matrix for `PaymentMethodInference` + the `Transaction.init`
/// hook and the backup DTO's optional column.
final class PaymentMethodInferenceTests: XCTestCase {

    func testAutoLoggedIsAlwaysBank() {
        XCTAssertEqual(PaymentMethodInference.infer(source: .autoLogged, text: "plata numerar"), .bank)
    }

    func testVoiceKeywords() {
        XCTAssertEqual(PaymentMethodInference.infer(source: .voice, text: "am dat 200 lei numerar la electrician"), .cash)
        XCTAssertEqual(PaymentMethodInference.infer(source: .voice, text: "50 lei cash parcare"), .cash)
        XCTAssertEqual(PaymentMethodInference.infer(source: .voice, text: "bani gheață pentru nisip"), .cash)
        XCTAssertEqual(PaymentMethodInference.infer(source: .manual, text: "plata cu cardul la OMV"), .bank)
        XCTAssertEqual(PaymentMethodInference.infer(source: .voice, text: "transfer către Ionescu"), .bank)
        XCTAssertNil(PaymentMethodInference.infer(source: .voice, text: "100 lei motorina"))
    }

    func testImportedDefaultsToBankUnlessCash() {
        XCTAssertEqual(PaymentMethodInference.infer(source: .imported, text: "COMISION ADMINISTRARE"), .bank)
        XCTAssertEqual(PaymentMethodInference.infer(source: .imported, text: "RETRAGERE NUMERAR ATM"), .cash)
    }

    func testTransactionInitInfersWhenNotGivenAndExplicitWins() {
        let inferred = Transaction(amount: 200, currency: .ron, context: .work,
                                   descriptionText: "electrician", rawTranscript: "200 lei cash electrician",
                                   source: .voice)
        XCTAssertEqual(inferred.paymentMethod, .cash)

        let explicit = Transaction(amount: 200, currency: .ron, context: .work,
                                   descriptionText: "cash electrician", source: .manual, paymentMethod: .bank)
        XCTAssertEqual(explicit.paymentMethod, .bank)

        let unknown = Transaction(amount: 200, currency: .ron, context: .work,
                                  descriptionText: "motorina", source: .manual)
        XCTAssertNil(unknown.paymentMethod)
        XCTAssertNil(unknown.paymentMethodRaw)
    }

    func testLegacyBackupRowWithoutColumnDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","amount":"12.5","currency":"RON","context":"personal",
         "descriptionText":"cafea","date":700000000,"source":"manual","direction":"expense","createdAt":700000000}
        """
        let dto = try JSONDecoder().decode(TransactionDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.paymentMethod)
        XCTAssertNil(try dto.makeModel().paymentMethod)
    }
}
