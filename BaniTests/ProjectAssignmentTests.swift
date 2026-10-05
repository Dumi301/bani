import XCTest
@testable import Bani

/// v1.2a — the smart-default project rule: Work entries pre-fill the last-used
/// project; Personal entries are never project-tagged (context gating).
final class ProjectAssignmentTests: XCTestCase {

    func testWorkUsesLastUsedProject() {
        let id = UUID()
        XCTAssertEqual(
            ProjectAssignment.smartDefault(context: .work, lastUsedRaw: id.uuidString),
            id
        )
    }

    func testPersonalNeverGetsAProject() {
        let id = UUID()
        XCTAssertNil(
            ProjectAssignment.smartDefault(context: .personal, lastUsedRaw: id.uuidString),
            "Personal transactions are never project-tagged"
        )
    }

    func testWorkWithNoLastUsedIsNil() {
        XCTAssertNil(ProjectAssignment.smartDefault(context: .work, lastUsedRaw: ""))
    }

    // MARK: - v0.4 labor default

    func testLaborDefaultNeedsWorkAndAPersonAndNoRule() {
        XCTAssertTrue(ProjectAssignment.laborDefault(context: .work, counterparty: "Ion", ruleMatched: false))
        XCTAssertFalse(ProjectAssignment.laborDefault(context: .work, counterparty: "Ion", ruleMatched: true), "a keyword rule wins")
        XCTAssertFalse(ProjectAssignment.laborDefault(context: .work, counterparty: "   ", ruleMatched: false))
        XCTAssertFalse(ProjectAssignment.laborDefault(context: .personal, counterparty: "Ion", ruleMatched: false))
    }

    func testWorkWithInvalidLastUsedIsNil() {
        XCTAssertNil(ProjectAssignment.smartDefault(context: .work, lastUsedRaw: "not-a-uuid"))
    }
}
