import Foundation
import Testing
@testable import PersistenceCore

/// The one unknown-row policy shared by every snapshot+tail op-log store
/// (audit 2026-08-02, findings 1 and 2).
///
/// The bug these pin: reading is TOLERANT (an op token this build does not know
/// is skipped, a malformed line is dropped) but compaction is DESTRUCTIVE — it
/// snapshots state folded from the decoded rows only and then rewrites the feed,
/// so every row the read skipped is deleted from the only place it existed. The
/// realistic trigger is version skew, not corruption: DeskSweepCLI and
/// task-ledger are separate SwiftPM products and nothing forces them to match
/// the running .app.
///
/// Every test here FAILS on the pre-fix code: it compacted regardless, and the
/// skipped rows are gone from the rewritten feed.
@Suite("Op-log unknown-row policy", .serialized)
struct OpLogUnknownRowPolicyTests {

    private func root(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oplog-unknown-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lines(_ path: URL) -> [String] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    private func appendRawLine(_ line: String, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: - 1. DeskStore: an op token from a newer build survives compaction

    /// A row this build cannot decode must still be on disk after the feed
    /// crosses the compaction threshold. PRE-FIX: `compactIfNeededUnlocked`
    /// wrote the base and truncated the tail to EMPTY, so the row was gone.
    @Test func deskRefusesToCompactOverAnUnknownOpTokenAndKeepsTheRow() async throws {
        let dir = try root("desk-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 4)

        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "one")
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "two")
        let third = try await store.createItem(kind: .plan, project: "NativeAgent", title: "three")

        // What a NEWER app writes and this build has never heard of.
        let futureRow = #"{"opId":"op-from-the-future","ts":"2026-08-02T00:00:00.000000Z","op":"set_moon_phase","handle":"\#(third.handle)","phase":"waxing"}"#
        try appendRawLine(futureRow, to: store.opsPath)

        // The read skips it — tolerant, and that part is correct …
        let integrity = try await store.opLogIntegrity()
        #expect(integrity.undecodableRowCount == 1)
        #expect(integrity.malformedLineCount == 0)
        #expect(!integrity.isClean)

        // … and this append takes the DECODED count to the threshold, which is
        // where the old code compacted and erased it.
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "four")

        #expect(!FileManager.default.fileExists(atPath: store.basePath.path),
                "compaction must REFUSE while a row is undecodable — a base here means the tail was truncated")
        #expect(lines(store.opsPath).contains(futureRow),
                "the unknown row must still be on disk, byte-for-byte")
        // The desk itself is unaffected: tolerant reads still project state.
        let state = try await store.liveState()
        #expect(state.items.count == 4)
    }

    /// The refusal is not a permanent wedge: once the unknown rows are gone (a
    /// build that understands them, or an operator repair) compaction resumes
    /// on the very next append.
    @Test func deskCompactsAgainOnceTheFeedIsDecodableAndReplayIsDeterministic() async throws {
        let dir = try root("desk-heal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 4)

        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "one")
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "two")
        let third = try await store.createItem(kind: .plan, project: "NativeAgent", title: "three")
        let futureRow = #"{"opId":"op-from-the-future","ts":"2026-08-02T00:00:00.000000Z","op":"set_moon_phase","handle":"\#(third.handle)"}"#
        try appendRawLine(futureRow, to: store.opsPath)
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "four")
        #expect(!FileManager.default.fileExists(atPath: store.basePath.path))

        // Drop the unknown row (stand-in for "a build that understands it ran").
        let repaired = lines(store.opsPath).filter { $0 != futureRow }
        try (repaired.joined(separator: "\n") + "\n").write(to: store.opsPath, atomically: true, encoding: .utf8)

        let beforeCompaction = try await store.liveState()
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "five")
        #expect(FileManager.default.fileExists(atPath: store.basePath.path),
                "a clean feed at threshold must compact — the gate is a guard, not an off switch")

        // REPLAY DETERMINISM: rebuild twice from the post-compaction base+tail
        // and compare. Both must equal each other AND still contain everything
        // that existed before the truncate.
        let rebuildA = try await store.liveState()
        let rebuildB = try await store.liveState()
        #expect(rebuildA == rebuildB, "two rebuilds of the same base+tail must be identical")
        let titlesBefore = Set(beforeCompaction.items.map(\.title))
        let titlesAfter = Set(rebuildA.items.map(\.title))
        #expect(titlesBefore.isSubset(of: titlesAfter), "compaction must not lose a single item")
        #expect(titlesAfter == titlesBefore.union(["five"]))
    }

    /// A malformed line in the MIDDLE of the feed blocks compaction too — the
    /// truncate would delete bytes nobody has ever read.
    @Test func deskRefusesToCompactOverAMalformedLine() async throws {
        let dir = try root("desk-malformed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 4)

        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "one")
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "two")
        try appendRawLine("{\"opId\":\"torn\",\"ts\":\"2026", to: store.opsPath)
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "three")
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "four")

        let integrity = try await store.opLogIntegrity()
        #expect(integrity.malformedLineCount == 1)
        #expect(!integrity.isClean)
        #expect(!FileManager.default.fileExists(atPath: store.basePath.path))
    }

    // MARK: - 2. TaskLedger: the same policy, same enforcement point

    @Test func taskLedgerRefusesToCompactOverAnUnknownEventKind() async throws {
        let dir = try root("ledger-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = SwiftNativeTaskLedger(dataRoot: dir, compactionThreshold: 4, keepTail: 1)

        for i in 1...2 {
            _ = try await ledger.append(TaskLedgerEvent(
                id: "e\(i)", taskId: "t\(i)", ts: TaskLedgerClock.nowISO(),
                actor: .claude, kind: .created, title: "task \(i)"
            ))
        }
        let futureRow = #"{"id":"e-future","taskId":"t1","ts":"2026-08-02T00:00:00.000000Z","actor":"claude","kind":"escalated","title":"a kind from a newer build"}"#
        try appendRawLine(futureRow, to: ledger.eventsPath)

        let integrity = try await ledger.feedIntegrity()
        #expect(integrity.undecodableRowCount == 1)

        for i in 3...4 {
            _ = try await ledger.append(TaskLedgerEvent(
                id: "e\(i)", taskId: "t\(i)", ts: TaskLedgerClock.nowISO(),
                actor: .claude, kind: .created, title: "task \(i)"
            ))
        }

        #expect(!FileManager.default.fileExists(atPath: ledger.basePath.path),
                "the ledger must refuse to fold a prefix it could not fully decode")
        #expect(lines(ledger.eventsPath).contains(futureRow))
        #expect(try await ledger.listTasks().count == 4)
    }

    // MARK: - 3. The scan itself: counted, not swallowed (finding 2)

    /// A torn TRAILING line stays tolerated (an append still in flight), a
    /// malformed line mid-file is counted. PRE-FIX both were invisible.
    @Test func jsonlScanCountsMidFileDamageButToleratesATornTail() async throws {
        let dir = try root("scan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let path = dir.appendingPathComponent("feed.jsonl")

        // Two good rows, one shredded row between them, then a torn tail with
        // NO closing newline.
        let body = "{\"a\":1}\n{\"broken\":\n{\"a\":2}\n{\"a\":3"
        try body.write(to: path, atomically: true, encoding: .utf8)

        let (rows, report) = try await core.readJSONLReporting(path)
        #expect(rows.count == 2, "the parseable rows are unchanged from readJSONL's old behaviour")
        #expect(report.malformedLineCount == 1, "the mid-file shred is REPORTED, not swallowed")
        #expect(report.trailingPartialLine, "the torn tail is tolerated and flagged")
        #expect(!report.isClean)

        // readJSONL keeps its exact old contract.
        let plain = try await core.readJSONL(path)
        #expect(plain == rows)
    }

    @Test func aHealthyFeedScansClean() async throws {
        let dir = try root("clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let path = dir.appendingPathComponent("feed.jsonl")
        try await core.appendJSONLDurable(.object(["a": .int(1)]), to: path)
        try await core.appendJSONLDurable(.object(["a": .int(2)]), to: path)

        let (rows, report) = try await core.readJSONLReporting(path)
        #expect(rows.count == 2)
        #expect(report.isClean)
        // Durable append is byte-identical to the buffered one — the only
        // difference is the F_FULLFSYNC before close.
        #expect(rows == [.object(["a": .int(1)]), .object(["a": .int(2)])])
    }

    @Test func durableBatchAppendMatchesTheBufferedShape() async throws {
        let dir = try root("durable-batch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let durable = dir.appendingPathComponent("durable.jsonl")
        let buffered = dir.appendingPathComponent("buffered.jsonl")
        let records: [JSONValue] = [.object(["n": .int(1)]), .object(["n": .int(2)])]
        try await core.appendJSONLDurable(records, to: durable)
        try await core.appendJSONL(records, to: buffered)
        #expect(try Data(contentsOf: durable) == (try Data(contentsOf: buffered)))
    }

    // MARK: - 4. The gate itself

    @Test func mayCompactIsTrueOnlyForACleanRead() {
        SnapshotTailOpLog.resetIntegrityLogMemoForTesting()
        let path = URL(fileURLWithPath: "/tmp/does-not-matter.jsonl")
        #expect(SnapshotTailOpLog.mayCompact(.clean, feed: "T", path: path))
        // A torn TRAILING line alone must NOT block compaction forever — it is
        // a write in flight, not a row we are about to destroy.
        #expect(SnapshotTailOpLog.mayCompact(
            .init(trailingPartialLine: true), feed: "T", path: path))
        #expect(!SnapshotTailOpLog.mayCompact(
            .init(undecodableRowCount: 1), feed: "T", path: path))
        #expect(!SnapshotTailOpLog.mayCompact(
            .init(malformedLineCount: 1), feed: "T", path: path))
    }
}
