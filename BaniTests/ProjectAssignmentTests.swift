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

    func testWorkWithInvalidLastUsedIsNil() {
        XCTAssertNil(ProjectAssignment.smartDefault(context: .work, lastUsedRaw: "not-a-uuid"))
    }
}
