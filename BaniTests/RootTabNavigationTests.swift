import XCTest
@testable import Bani

/// P7 gate — the v2 teardown tab structure: four tabs, **Raport first**, no Finances
/// tab (it is now a drill-down inside the hub). The tab identity is an enum so the
/// structure is asserted without instantiating SwiftUI; the Finances-as-drill-down
/// seam is proven by the embeddable `FinancesView` initializer, and the hub model's
/// empty-state safety by building it with no data.
final class RootTabNavigationTests: XCTestCase {

    func testFourTabsRaportFirstNoFinancesTab() {
        XCTAssertEqual(RootTab.allCases, [.raport, .log, .projects, .settings])
        XCTAssertEqual(RootTab.allCases.first, .raport)
        XCTAssertEqual(RootTab.allCases.count, 4)
        XCTAssertFalse(RootTab.allCases.contains { $0.rawValue == "finances" },
                       "Finances is no longer a tab — it is a drill-down inside the Raport hub")
    }

    @MainActor
    func testFinancesReachableAsEmbeddedDrillDown() {
        // The hub reuses the whole Finances surface by PUSHING it embedded (no own
        // NavigationStack). That initializer is the reachable-drill-down contract.
        let embedded = FinancesView(embedInNavigationStack: false)
        XCTAssertFalse(embedded.embedInNavigationStack)
        let standalone = FinancesView()
        XCTAssertTrue(standalone.embedInNavigationStack, "default stays tab-root-safe")
    }

    func testHubModelIsEmptyStateSafeWithNoData() {
        let model = RaportHubBuilder.build(
            lines: [], loans: [], projects: [], items: [],
            rate: nil, horizon: .days30,
            cashflowInterval: DateInterval(start: .distantPast, end: .distantFuture)
        )
        XCTAssertEqual(model.position.netLoggedPosition, 0)
        XCTAssertEqual(model.position.liquidity.freeLiquidity, 0)
        XCTAssertEqual(model.position.cashIn, 0)
        XCTAssertEqual(model.position.cashOut, 0)
        XCTAssertTrue(model.receivables.people.isEmpty)
        XCTAssertTrue(model.bankDebt.isEmpty)
        XCTAssertTrue(model.investorDebt.isEmpty)
        XCTAssertTrue(model.projects.isEmpty)
    }
}
