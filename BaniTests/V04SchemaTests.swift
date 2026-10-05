import XCTest
import SwiftData
@testable import Bani

/// v0.4 P0 — schema prep for the redesign. Proves, on a REAL on-disk store
/// (write → close → reopen), that the additive optionals this push adds to
/// entities that already carry live rows are migration-safe:
///   • `Project.parentProjectID / expectedSalePrice / expectedSaleDate / aliasesRaw`
///   • `Person.roleRaw`
///   • `updatedAt` on every user-data entity (stamped by `SyncStamp`)
///   • `ProjectStatus.prospect` (additive case) and the 17th seeded custom.
/// A store written in the 0.3 shape reopens with every new column nil and no
/// data loss; the new fields round-trip; the stamp hook sets `updatedAt`.

/// The 0.3 shape of `Project` / `Person` — every column that existed BEFORE
/// this run. Nested so the SwiftData entity names stay "Project" / "Person"
/// (same on-disk tables), the versioned-schema idiom used by every migration
/// test in this target.
private enum LegacyStoreV03 {
    @Model final class Project {
        var id: UUID
        var name: String
        var status: ProjectStatus
        var colorIndex: Int
        var sortOrder: Int
        var archived: Bool
        var createdAt: Date
        init(id: UUID = UUID(), name: String, status: ProjectStatus = .active, colorIndex: Int,
             sortOrder: Int = 0, archived: Bool = false, createdAt: Date = .now) {
            self.id = id; self.name = name; self.status = status; self.colorIndex = colorIndex
            self.sortOrder = sortOrder; self.archived = archived; self.createdAt = createdAt
        }
    }
    @Model final class Person {
        var id: UUID
        var name: String
        var normalizedName: String
        var kindRaw: String?
        var notes: String?
        var createdAt: Date
        init(id: UUID = UUID(), name: String, normalizedName: String, kindRaw: String? = nil,
             notes: String? = nil, createdAt: Date = .now) {
            self.id = id; self.name = name; self.normalizedName = normalizedName
            self.kindRaw = kindRaw; self.notes = notes; self.createdAt = createdAt
        }
    }
}

private func freshStoreURL(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bani-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("store.sqlite")
}

private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(for: BaniModelContainer.schema, configurations: ModelConfiguration(url: url))
}

@MainActor
final class V04SchemaTests: XCTestCase {

    // MARK: - Migration

    func testV03ProjectAndPersonRowsReopenWithNewColumnsNilAndNoDataLoss() throws {
        let url = try freshStoreURL("v04-legacy")
        let lotID = UUID(), ionID = UUID()

        do {
            let container = try ModelContainer(
                for: LegacyStoreV03.Project.self, LegacyStoreV03.Person.self,
                configurations: ModelConfiguration(url: url)
            )
            let ctx = container.mainContext
            ctx.insert(LegacyStoreV03.Project(id: lotID, name: "Crângași", status: .finished, colorIndex: 2, sortOrder: 4))
            ctx.insert(LegacyStoreV03.Person(id: ionID, name: "Ion", normalizedName: "ion", kindRaw: "vendor"))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let ctx = container.mainContext

        let project = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Project>()).first)
        XCTAssertEqual(project.id, lotID)
        XCTAssertEqual(project.name, "Crângași")
        XCTAssertEqual(project.status, .finished)
        XCTAssertEqual(project.colorIndex, 2)
        XCTAssertEqual(project.sortOrder, 4)
        XCTAssertNil(project.parentProjectID)
        XCTAssertNil(project.expectedSalePrice)
        XCTAssertNil(project.expectedSaleDate)
        XCTAssertNil(project.aliasesRaw)
        XCTAssertNil(project.updatedAt, "legacy rows carry no stamp until they are next saved")
        XCTAssertEqual(project.aliases, [])

        let person = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Person>()).first)
        XCTAssertEqual(person.id, ionID)
        XCTAssertEqual(person.kind, .vendor)
        XCTAssertNil(person.roleRaw)
        XCTAssertNil(person.updatedAt)
    }

    func testProjectTreeAndPersonRoleRoundTrip() throws {
        let url = try freshStoreURL("v04-roundtrip")
        let lotID = UUID(), houseID = UUID()
        let saleDate = Date(timeIntervalSince1970: 1_780_000_000)

        do {
            let ctx = try currentContainer(at: url).mainContext
            ctx.insert(Project(id: lotID, name: "Lot Crângași", status: .prospect, colorIndex: 0,
                               expectedSalePrice: 150_000, expectedSaleDate: saleDate,
                               aliasesRaw: " crangasi , lotul ,, "))
            ctx.insert(Project(id: houseID, name: "Casa 3", colorIndex: 1, parentProjectID: lotID))
            ctx.insert(Person(name: "Ion", normalizedName: "ion", role: "electrician"))
            try ctx.save()
        }

        let ctx = try currentContainer(at: url).mainContext
        let projects = try ctx.fetch(FetchDescriptor<Project>())
        let lot = try XCTUnwrap(projects.first { $0.id == lotID })
        let house = try XCTUnwrap(projects.first { $0.id == houseID })
        XCTAssertEqual(lot.status, .prospect)
        XCTAssertEqual(lot.expectedSalePrice, 150_000)
        XCTAssertEqual(lot.expectedSaleDate, saleDate)
        XCTAssertEqual(lot.aliases, ["crangasi", "lotul"], "aliases trim + drop empties")
        XCTAssertEqual(lot.snapshot.aliases, ["crangasi", "lotul"])
        XCTAssertNil(lot.parentProjectID)
        XCTAssertEqual(house.parentProjectID, lotID, "a child points at its parent by id")
        XCTAssertEqual(house.snapshot.parentProjectID, lotID)

        let ion = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Person>()).first)
        XCTAssertEqual(ion.roleRaw, "electrician")
        XCTAssertEqual(ion.snapshot.role, "electrician")
    }

    // MARK: - Backup DTOs

    func testProjectAndPersonDTOsCarryTheNewColumns() throws {
        let lotID = UUID()
        let project = Project(name: "Casa 2", colorIndex: 3, parentProjectID: lotID,
                              expectedSalePrice: Decimal(string: "99999.50")!, aliasesRaw: "casa doi")
        let restored = try ProjectDTO(project).makeModel()
        XCTAssertEqual(restored.parentProjectID, lotID)
        XCTAssertEqual(restored.expectedSalePrice, Decimal(string: "99999.50")!)
        XCTAssertEqual(restored.aliasesRaw, "casa doi")

        let bare = try ProjectDTO(Project(name: "Vechi", colorIndex: 0)).makeModel()
        XCTAssertNil(bare.parentProjectID)
        XCTAssertNil(bare.expectedSalePrice)

        let person = PersonDTO(Person(name: "Ion", normalizedName: "ion", role: "zidar")).makeModel()
        XCTAssertEqual(person.roleRaw, "zidar")
    }

    // MARK: - Enum + seeds

    func testProspectRawValueStableAndSaleCategorySeeded() {
        XCTAssertEqual(ProjectStatus.prospect.rawValue, "prospect")
        XCTAssertEqual(ProjectStatus.allCases.count, 3)
        XCTAssertEqual(SeededCustomCategory.allCases.last, .vanzareProprietate, "appended last — order drives color + seeding")
        XCTAssertEqual(SeededCustomCategory.vanzareProprietate.displayName, "Vânzare proprietate")
        XCTAssertEqual(ObservatiiVocabulary.match("pret vanzare"), .vanzareProprietate)
        XCTAssertEqual(ObservatiiVocabulary.match("vanzare apartament"), .vanzareProprietate)
        XCTAssertEqual(ObservatiiVocabulary.match("materiale"), .materialeConstructii, "existing vocabulary untouched")
    }

    // MARK: - SyncStamp

    func testSyncStampSetsUpdatedAtOnInsertAndOnChange() throws {
        let container = try BaniModelContainer.make(inMemory: true)
        let ctx = container.mainContext
        SyncStamp.shared.install(on: ctx)

        let project = Project(name: "Casa 1", colorIndex: 0)
        let tx = Transaction(amount: 500, currency: .ron, context: .work,
                             descriptionText: "manoperă Ion", source: .manual)
        XCTAssertNil(project.updatedAt, "unsaved rows carry no stamp")
        ctx.insert(project)
        ctx.insert(tx)
        try ctx.save()

        let first = try XCTUnwrap(project.updatedAt, "insert + save must stamp")
        XCTAssertNotNil(tx.updatedAt)
        XCTAssertGreaterThanOrEqual(first, project.createdAt.addingTimeInterval(-1))

        project.name = "Casa 1 (renovată)"
        try ctx.save()
        let second = try XCTUnwrap(project.updatedAt)
        XCTAssertGreaterThanOrEqual(second, first, "a change re-stamps")

        // Installing twice is a no-op (one observer per context).
        SyncStamp.shared.install(on: ctx)
        project.sortOrder = 9
        try ctx.save()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(project.updatedAt), second)
    }
}
