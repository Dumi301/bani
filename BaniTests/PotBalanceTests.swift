import XCTest
@testable import Bani

/// v0.3 gate — two pots on Raport: cash anchor 5 000, cash expense 1 200, bank
/// expense 300 → cash 3 800, bank = bank anchor − 300; unknown rows count as bank.
final class PotBalanceTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func anchor(_ pot: PaymentMethod, _ amount: Decimal, daysAgo: Double) -> BalanceAnchorSnapshot {
        BalanceAnchorSnapshot(id: UUID(), amount: amount, currency: .ron,
                              anchoredAt: now.addingTimeInterval(-daysAgo * 86_400),
                              driftAtAnchor: 0, note: nil, unresolvedResidual: nil,
                              createdAt: now, pot: pot)
    }

    private func line(_ direction: TransactionDirection, _ amount: Decimal,
                      _ method: PaymentMethod?, daysAgo: Double = 1) -> RaportTxLine {
        RaportTxLine(amount: amount, currency: .ron, direction: direction, projectID: nil, loanID: nil,
                     date: now.addingTimeInterval(-daysAgo * 86_400), paymentMethod: method)
    }

    func testCashAndBankPotsSplitByPaymentMethod() {
        let anchors = [anchor(.cash, 5000, daysAgo: 10), anchor(.bank, 20_000, daysAgo: 10)]
        let lines = [
            line(.expense, 1200, .cash),
            line(.expense, 300, .bank),
            line(.expense, 100, nil),                 // unknown → bank
            line(.neutral, 999, .cash),               // transfers never move a pot
            line(.expense, 50, .cash, daysAgo: 20),   // before the anchor → already inside it
        ]
        let cash = RaportHubBuilder.potBalance(.cash, lines: lines, anchors: anchors, rate: nil)
        let bank = RaportHubBuilder.potBalance(.bank, lines: lines, anchors: anchors, rate: nil)
        XCTAssertEqual(cash.balance, 3800)
        XCTAssertTrue(cash.hasAnchor)
        XCTAssertEqual(bank.balance, 19_600)
        XCTAssertTrue(bank.hasAnchor)
    }

    func testUnanchoredCashPotIsFlaggedAndSumsItsFlows() {
        let lines = [line(.income, 700, .cash), line(.expense, 200, .cash)]
        let cash = RaportHubBuilder.potBalance(.cash, lines: lines, anchors: [], rate: nil)
        XCTAssertEqual(cash.balance, 500)
        XCTAssertFalse(cash.hasAnchor)
    }

    func testLegacyAnchorReadsAsBank() {
        let legacy = BalanceAnchor(amount: 10, currency: .ron)
        XCTAssertNil(legacy.potRaw)
        XCTAssertEqual(legacy.pot, .bank)
        let cash = BalanceAnchor(amount: 10, currency: .ron, pot: .cash)
        XCTAssertEqual(cash.potRaw, "cash")
        XCTAssertEqual(cash.snapshot.pot, .cash)
    }
}
