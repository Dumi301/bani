import XCTest
@testable import Bani

/// Part B — the App Group handoff. The container is unavailable in the CI
/// simulator, so the round-trip is proven on the directory-injectable core
/// (`SharedPayloadStore.write*/drain(from:)` — the exact extension-side logic):
/// write text/image → drain → parse. Drain also REMOVES processed files.
final class AppGroupRoundTripTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bani-appgroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTextPayloadRoundTripsAndParses() throws {
        XCTAssertTrue(SharedPayloadStore.writeText("Plata 45,00 RON la MEGA IMAGE", to: dir))

        let drained = SharedPayloadStore.drain(from: dir)
        XCTAssertEqual(drained.count, 1)
        let d = try XCTUnwrap(drained.first)
        XCTAssertEqual(d.payload.kind, .text)
        XCTAssertEqual(d.payload.text, "Plata 45,00 RON la MEGA IMAGE")
        XCTAssertNil(d.imageData)

        // The drained text parses through the bank-notification parser.
        let parse = BankNotificationParser.parse(try XCTUnwrap(d.payload.text))
        XCTAssertEqual(parse.amount, Decimal(string: "45"))
        XCTAssertEqual(parse.merchant, "MEGA IMAGE")
    }

    func testImagePayloadRoundTripsBytes() throws {
        let bytes = Data([0xFF, 0xD8, 0xAA, 0x00, 0x42, 0x99])
        XCTAssertTrue(SharedPayloadStore.writeImage(bytes, to: dir))

        let drained = SharedPayloadStore.drain(from: dir)
        XCTAssertEqual(drained.count, 1)
        let d = try XCTUnwrap(drained.first)
        XCTAssertEqual(d.payload.kind, .image)
        XCTAssertEqual(d.imageData, bytes, "image bytes must survive the App Group handoff verbatim")
    }

    func testDrainRemovesProcessedFilesAndOrdersOldestFirst() throws {
        SharedPayloadStore.writeText("first", to: dir)
        SharedPayloadStore.writeText("second", to: dir)

        let first = SharedPayloadStore.drain(from: dir)
        XCTAssertEqual(first.count, 2)
        // Oldest-first ordering.
        XCTAssertLessThanOrEqual(first[0].payload.receivedAt, first[1].payload.receivedAt)

        // A second drain finds nothing — processed exactly once.
        XCTAssertTrue(SharedPayloadStore.drain(from: dir).isEmpty)
    }

    func testDrainOnMissingDirectoryIsEmpty() {
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertTrue(SharedPayloadStore.drain(from: missing).isEmpty)
    }
}
