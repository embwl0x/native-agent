import Testing
import Foundation
@testable import PersistenceCore

// F8 (upgrade-sweep-2026-08). The live `activity/events.jsonl` sat at 4,822 of
// its 5,000-line budget (96%) and the instrument asked the obvious question:
// does eviction actually fire when it reaches the threshold?
//
// It did not. `enforceJSONLLineCap` short-circuits on
// `trimWhenBytesExceed` — for activity that trigger is 4 MiB, and at the live
// ~627-byte average row, 5,000 rows is only 3.1 MiB. The line cap could not be
// evaluated until the feed had grown to roughly 6,700 lines (134% of its own
// budget). The byte trigger was silently the real cap, and the line number in
// the registry was decoration.
//
// These tests pin the fixed behaviour at the F2 path-owned chokepoint: the line
// budget is the binding constraint, the byte trigger only amortizes HOW OFTEN
// it is counted, and the overshoot is bounded by the stride rather than by row
// size.
@Suite(.serialized)
struct ActivityEventsEvictionTests {

    private func makeFeed() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("activity-eviction-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("activity", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        JSONLCapCheckCounter.shared._testReset()
        return dir.appendingPathComponent("events.jsonl")
    }

    private func lineCount(_ path: URL) throws -> Int {
        let text = try String(contentsOf: path, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func seed(_ rows: Range<Int>, at path: URL) throws {
        let text = try rows.map { try row($0).serialize(pretty: false) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: path)
    }

    /// A row roughly the size of a real activity row (~627 bytes live), so the
    /// feed reaches its LINE cap long before the 4 MiB byte trigger — the exact
    /// shape that hid the bug.
    private func row(_ index: Int) -> JSONValue {
        .object([
            "seq": .int(Int64(index)),
            "kind": .string("activity"),
            "payload": .string(String(repeating: "x", count: 560)),
        ])
    }

    private func row(_ index: Int, kind: String) -> JSONValue {
        .object([
            "seq": .int(Int64(index)),
            "kind": .string(kind),
        ])
    }

    @Test
    func activityEventsIsRegisteredAtFiveThousandLines() throws {
        let feed = try makeFeed()
        let policy = try #require(jsonlPathOwnedCapPolicy(for: feed))
        #expect(policy.maxLines == JSONLLineCaps.activityEvents)
        #expect(policy.maxLines == 5000)
        #expect(policy.trimWhenBytesExceed == JSONLLineCaps.activityTrimTriggerBytes)
    }

    /// THE F8 CLAIM: crossing the 5,000-line threshold evicts, without the
    /// feed ever reaching the 4 MiB byte trigger.
    @Test
    func evictionFiresAtTheLineThresholdBelowTheByteTrigger() async throws {
        let feed = try makeFeed()
        let persistence = SwiftNativePersistenceCore()
        let cap = JSONLLineCaps.activityEvents

        // Seed the exact boundary directly, then exercise the capped append
        // once. Appending all 5,000 setup rows through a stride-1 cap check
        // rereads a growing multi-megabyte file each time (quadratic harness
        // work) without proving anything beyond this single transition.
        try seed(0..<cap, at: feed)
        JSONLCapCheckCounter.shared._testReset()
        try await appendJSONLCapped(
            row(cap),
            to: feed,
            using: persistence,
            logLabel: "F8Test",
            capCheckStride: 1
        )

        let bytes = try Data(contentsOf: feed).count
        #expect(
            bytes < JSONLLineCaps.activityTrimTriggerBytes,
            "the feed reached the \(JSONLLineCaps.activityTrimTriggerBytes)-byte trigger (\(bytes)) — this test no longer proves the LINE cap fired"
        )
        #expect(try lineCount(feed) == cap)

        // The eviction is FIFO: the newest rows survive, the oldest are gone.
        let text = try String(contentsOf: feed, encoding: .utf8)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        func seq(_ line: Substring) -> Int64? {
            guard let value = try? JSONValue.parse(Data(line.utf8)),
                  case .object(let obj) = value,
                  case .int(let n)? = obj["seq"] else { return nil }
            return n
        }
        #expect(rows.first.flatMap(seq) == 1)
        #expect(rows.last.flatMap(seq) == Int64(cap))
    }

    /// Negative control on the boundary: at exactly the cap nothing is dropped.
    @Test
    func nothingIsEvictedBelowTheThreshold() async throws {
        let feed = try makeFeed()
        let persistence = SwiftNativePersistenceCore()
        let cap = JSONLLineCaps.activityEvents
        try seed(0..<(cap - 1), at: feed)
        JSONLCapCheckCounter.shared._testReset()
        try await appendJSONLCapped(
            row(cap - 1), to: feed, using: persistence,
            logLabel: "F8Test", capCheckStride: 1
        )
        #expect(try lineCount(feed) == JSONLLineCaps.activityEvents)
    }

    /// The regression itself: with the byte trigger as the ONLY gate — the
    /// pre-F8 behaviour — the feed sails past its line budget. This is the
    /// negative control that proves the fix is doing the work, not the test.
    @Test
    func byteTriggerAloneLetsTheFeedExceedItsLineBudget() throws {
        let feed = try makeFeed()
        try seed(0..<(JSONLLineCaps.activityEvents + 500), at: feed)
        let bytes = try Data(contentsOf: feed).count
        #expect(bytes < JSONLLineCaps.activityTrimTriggerBytes)

        let droppedWithTrigger = try enforceJSONLLineCap(
            at: feed,
            maxLines: JSONLLineCaps.activityEvents,
            trimWhenBytesExceed: JSONLLineCaps.activityTrimTriggerBytes
        )
        #expect(droppedWithTrigger == 0, "pre-F8 behaviour changed — restate this control")
        #expect(try lineCount(feed) == JSONLLineCaps.activityEvents + 500)

        let droppedWithoutTrigger = try enforceJSONLLineCap(
            at: feed, maxLines: JSONLLineCaps.activityEvents
        )
        #expect(droppedWithoutTrigger == 500)
        #expect(try lineCount(feed) == JSONLLineCaps.activityEvents)
    }

    /// At the production stride the overshoot is bounded by the stride, not by
    /// row size — the property that makes the amortization safe.
    @Test
    func productionStrideBoundsTheOvershoot() async throws {
        let feed = try makeFeed()
        let persistence = SwiftNativePersistenceCore()
        let cap = JSONLLineCaps.activityEvents
        let stride = JSONLLineCaps.capCheckStride
        // Setup rows do not need 5,000 individual durable appends. Begin at
        // the real boundary and exercise three complete production strides.
        try seed(0..<cap, at: feed)
        JSONLCapCheckCounter.shared._testReset()
        for index in cap..<(cap + 3 * stride) {
            try await appendJSONLCapped(
                row(index), to: feed, using: persistence, logLabel: "F8Test"
            )
        }
        let lines = try lineCount(feed)
        #expect(lines >= cap)
        #expect(
            lines <= cap + stride,
            "overshoot \(lines - cap) lines exceeds the \(stride)-append stride"
        )
    }

    /// A fresh process checks on its FIRST append to a path, so a feed
    /// inherited over its cap is trimmed at the next write rather than after
    /// another full stride.
    @Test
    func firstAppendAfterRestartTrimsAnInheritedOverCapFeed() async throws {
        let feed = try makeFeed()
        try seed(0..<(JSONLLineCaps.activityEvents + 300), at: feed)

        JSONLCapCheckCounter.shared._testReset()
        try await appendJSONLCapped(
            row(99_999),
            to: feed,
            using: SwiftNativePersistenceCore(),
            logLabel: "F8Test"
        )
        #expect(try lineCount(feed) == JSONLLineCaps.activityEvents)
    }

    @Test
    func activityTrimRetainsRareKindsInsideTheSameBudget() throws {
        let feed = try makeFeed()
        var rows: [JSONValue] = [row(0, kind: "approval"), row(1, kind: "provider")]
        rows.append(contentsOf: (2..<15).map { row($0, kind: "chat") })
        let text = try rows.map { try $0.serialize(pretty: false) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: feed)

        let dropped = try enforceActivityEventsLineCap(
            at: feed,
            maxLines: 10,
            minimumRowsPerKind: 2
        )
        #expect(dropped == 5)
        let kept = try String(contentsOf: feed, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONValue.parse(Data($0.utf8)) }
        let kinds = kept.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let kind)? = object["kind"] else { return nil }
            return kind
        }
        #expect(kept.count == 10)
        #expect(kinds.contains("approval"))
        #expect(kinds.contains("provider"))
        #expect(kinds.filter { $0 == "chat" }.count == 8)
    }

    @Test
    func genericJSONLTrimRemainsStrictFIFO() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("generic-eviction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feed = root.appendingPathComponent("events.jsonl")
        let rows = [row(0, kind: "rare")] + (1..<12).map { row($0, kind: "common") }
        let text = try rows.map { try $0.serialize(pretty: false) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: feed)

        #expect(try enforceJSONLLineCap(at: feed, maxLines: 10) == 2)
        let remaining = try String(contentsOf: feed, encoding: .utf8)
        #expect(!remaining.contains(#""kind":"rare""#))
    }

    /// F2's chokepoint still stands: a raw append to this feed fails loud.
    @Test
    func rawAppendToActivityEventsStillThrows() async throws {
        let feed = try makeFeed()
        await #expect(throws: JSONLPathOwnedAppendError.self) {
            try await SwiftNativePersistenceCore().appendJSONL(row(0), to: feed)
        }
    }
}
