import XCTest
import SwiftData
@testable import Bani

/// v2 "Recurring ScheduledItems" - the mark-done -> recurrence hook lives in
/// `ScheduledItemStore.markDone` (see `generateNextRecurrenceIfNeeded`). These
/// tests prove: exactly one next occurrence per completion, no duplicates on
/// re-entry, the next date is computed from the ORIGIN dueDate (not "now"), and
/// legacy rows written before this run (nil `recurrenceRaw` / `seriesID`)
/// migrate safely and behave as one-shot items.

/// The v2-pre-recurrence shape of the persisted `ScheduledItem`: every column
/// that existed BEFORE this run added `recurrenceRaw` / `seriesID`. Nested in an
/// enum so its SwiftData entity name is still `"ScheduledItem"` (the same
/// on-disk table as `Bani.ScheduledItem`) while the Swift type stays distinct -
/// mirrors `LegacyStoreV36` in `ProjectMigrationTests`.
private enum LegacyScheduledItemStore {
    @Model final class ScheduledItem {
        var id: UUID
        var direction: Bani.ScheduledDirection
        var amount: Decimal
        var currency: Bani.Currency
        var title: String
        var descriptionText: String
        var counterparty: String?
        var dueDate: Date
        var projectID: UUID?
        var status: Bani.ScheduledStatus
        var linkedTransactionID: UUID?
        var createdAt: Date

        init(id: UUID = UUID(), direction: Bani.ScheduledDirection, amount: Decimal, currency: Bani.Currency,
             title: String, descriptionText: String = "", counterparty: String? = nil, dueDate: Date,
             projectID: UUID? = nil, status: Bani.ScheduledStatus = .pending, linkedTransactionID: UUID? = nil,
             createdAt: Date = .now) {
            self.id = id
            self.direction = direction
            self.amount = amount
            self.currency = currency
            self.title = title
            self.descriptionText = descriptionText
            self.counterparty = counterparty
            self.dueDate = dueDate
            self.projectID = projectID
            self.status = status
            self.linkedTransactionID = linkedTransactionID
            self.createdAt = createdAt
        }
    }
}

/// A fresh, empty on-disk store URL in a temp directory.
private func freshStoreURL(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bani-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("store.sqlite")
}

/// The current app's full model set (mirrors `ProjectMigrationTests.currentContainer`).
private func currentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Transaction.self, CategoryRule.self, DecisionRecord.self, ContextRule.self,
        CorrectionMemory.self, CustomCategory.self, ImportBatch.self,
        Project.self, ScheduledItem.self,
        configurations: ModelConfiguration(url: url)
    )
}

@MainActor
final class ScheduledItemRecurrenceTests: XCTestCase {

    private func bucharestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    /// Returns the container (NOT just its context) so the caller retains it for
    /// the test's lifetime - mirrors `ScheduledItemLifecycleTests.makeContainer`.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transaction.self, ScheduledItem.self, Project.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    // MARK: - Mark-done generates exactly one next occurrence

    func testMarkDoneOnRecurringItemCreatesExactlyOneNextPendingOccurrence() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let due = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let item = ScheduledItem(direction: .outgoing, amount: 3500, currency: .ron, title: "Chirie",
                                 dueDate: due, recurrence: .monthly)
        ctx.insert(item)
        try ctx.save()

        ScheduledItemStore.markDone(item, calendar: cal, in: ctx)

        XCTAssertEqual(item.status, .done)
        XCTAssertNotNil(item.seriesID, "mark-done mints a seriesID for the origin item")

        let all = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        XCTAssertEqual(all.count, 2, "the origin item plus exactly one next occurrence")

        let pending = all.filter { $0.status == .pending }
        XCTAssertEqual(pending.count, 1, "exactly one pending occurrence exists")
        let nextOccurrence = try XCTUnwrap(pending.first)
        XCTAssertEqual(nextOccurrence.seriesID, item.seriesID, "the new occurrence shares the origin's seriesID")
        XCTAssertEqual(nextOccurrence.dueDate, cal.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 9))!)
        XCTAssertEqual(nextOccurrence.title, item.title)
        XCTAssertEqual(nextOccurrence.amount, item.amount)
    }

    /// A one-shot (`.none`) item never spawns an occurrence.
    func testMarkDoneOnNonRecurringItemCreatesNoOccurrence() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let item = ScheduledItem(direction: .outgoing, amount: 100, currency: .ron, title: "one-shot", dueDate: Date())
        ctx.insert(item)
        try ctx.save()

        ScheduledItemStore.markDone(item, in: ctx)

        let all = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        XCTAssertEqual(all.count, 1, "no next occurrence for a .none item")
        XCTAssertNil(item.seriesID)
    }

    // MARK: - No-duplicate guard (re-entry)

    /// Calling `markDone` a second time on the SAME already-done origin item
    /// (a defensive re-entry case - the UI never offers "mark done" on a done
    /// item, but the store must still be idempotent) must NOT create a second
    /// next occurrence: the guard finds the pending occurrence already created
    /// by the first call (same seriesID) and skips.
    func testMarkDoneTwiceOnSameItemDoesNotDuplicateNextOccurrence() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let item = ScheduledItem(direction: .outgoing, amount: 1000, currency: .ron, title: "Rate",
                                 dueDate: Date(), recurrence: .weekly)
        ctx.insert(item)
        try ctx.save()

        ScheduledItemStore.markDone(item, calendar: cal, in: ctx)
        let seriesIDAfterFirst = item.seriesID
        ScheduledItemStore.markDone(item, calendar: cal, in: ctx)

        XCTAssertEqual(item.seriesID, seriesIDAfterFirst, "seriesID does not change on re-entry")

        let allScheduled = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        let pendingInSeries = allScheduled.filter { $0.seriesID == item.seriesID && $0.status == .pending }
        XCTAssertEqual(pendingInSeries.count, 1, "re-entry must not create a second next occurrence")
        XCTAssertEqual(allScheduled.count, 2, "still just the origin + one occurrence, not three")
    }

    // MARK: - Overdue recurring item: next date from dueDate, not "now"

    /// An overdue item marked done LATE still recurs from its ORIGINAL due date,
    /// never from the moment it was completed. This is the documented semantics:
    /// a rent item due Jan 10 but marked done on Feb 5 must generate its next
    /// occurrence for Feb 10 (one month after the ORIGIN dueDate), not Mar 5
    /// (one month after "now"/the completion date).
    func testOverdueRecurringItemMarkedDoneComputesNextFromOriginDueDateNotNow() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let cal = bucharestCalendar()
        let originDue = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9))!
        let completedLate = cal.date(from: DateComponents(year: 2026, month: 2, day: 5, hour: 12))!
        let item = ScheduledItem(direction: .outgoing, amount: 2000, currency: .ron, title: "Chirie",
                                 dueDate: originDue, recurrence: .monthly)
        ctx.insert(item)
        try ctx.save()
        XCTAssertTrue(item.isOverdue(asOf: completedLate), "sanity: the item is overdue when marked done")

        ScheduledItemStore.markDone(item, date: completedLate, calendar: cal, in: ctx)

        let pending = try ctx.fetch(FetchDescriptor<ScheduledItem>()).filter { $0.status == .pending }
        let nextOccurrence = try XCTUnwrap(pending.first)
        let expectedFromOriginDueDate = cal.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: 9))!
        XCTAssertEqual(nextOccurrence.dueDate, expectedFromOriginDueDate,
                        "next due date = origin dueDate + 1 month, NOT completedLate + 1 month")
        XCTAssertNotEqual(nextOccurrence.dueDate, cal.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12))!,
                           "must not have been computed from the late completion date")
    }

    // MARK: - Migration: legacy nil recurrenceRaw / seriesID

    /// A `ScheduledItem` row written before this run (no `recurrenceRaw` /
    /// `seriesID` columns at all) reopens under the CURRENT schema: it decodes
    /// to `.none` / `nil` (legal Optional decode, zero data loss - the
    /// `Bani-2026-08-02` law) and behaves as a normal one-shot item on mark-done.
    func testLegacyScheduledItemRowsWithNilRecurrenceAndSeriesIDMigrateAndBehaveAsNone() throws {
        let url = try freshStoreURL("sched-recur-legacy")
        let itemID = UUID()
        let due = Date(timeIntervalSince1970: 1_770_000_000)

        do {
            let container = try ModelContainer(
                for: LegacyScheduledItemStore.ScheduledItem.self,
                configurations: ModelConfiguration(url: url)
            )
            let ctx = container.mainContext
            ctx.insert(LegacyScheduledItemStore.ScheduledItem(
                id: itemID, direction: .outgoing, amount: 6000, currency: .ron,
                title: "Chirie", counterparty: "Ion", dueDate: due, status: .pending
            ))
            try ctx.save()
        }

        let container = try currentContainer(at: url)
        let ctx = container.mainContext
        let rows = try ctx.fetch(FetchDescriptor<ScheduledItem>())

        XCTAssertEqual(rows.count, 1, "the legacy row must migrate into the current schema")
        let row = try XCTUnwrap(rows.first { $0.id == itemID })
        XCTAssertEqual(row.recurrence, .none, "nil recurrenceRaw must read as .none, not crash")
        XCTAssertNil(row.seriesID)
        XCTAssertEqual(row.amount, 6000)
        XCTAssertEqual(row.title, "Chirie")
        XCTAssertEqual(row.counterparty, "Ion")

        // Behaves as a normal one-shot item: marking it done does NOT spawn a
        // next occurrence, since recurrence == .none.
        ScheduledItemStore.markDone(row, in: ctx)
        let allAfterMarkDone = try ctx.fetch(FetchDescriptor<ScheduledItem>())
        XCTAssertEqual(allAfterMarkDone.count, 1, "a .none item must not spawn a next occurrence on mark-done")
        XCTAssertEqual(row.status, .done)
    }
}
