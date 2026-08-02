import Foundation
import Darwin
import Testing
@testable import PersistenceCore

/// The compaction threshold must key on PHYSICAL rows, the health of a feed
/// must be READABLE, and a delegating conformer must never be able to report a
/// clean scan it did not perform (gpt-5.5 review 2026-08-02, findings 2/3/4).
///
/// THE BUG FINDING 2 PINS: every store's threshold counted DECODED entries
/// while its comment claimed it keyed on file size. A stale binary facing 100k
/// rows written by a newer build plus 10 it understands computed a feed size of
/// 10 — under every threshold — so `compactIfNeededUnlocked` returned before
/// reaching `mayCompact`. The refusal warning, which is the ONLY product signal
/// that compaction is wedged, therefore never fired in exactly the situation it
/// exists for, while the feed grew without bound.
///
/// The tests that assert the refusal WARNING fail on the pre-fix code: it never
/// reached the gate at all.
@Suite("Op-log physical-row threshold", .serialized)
struct OpLogPhysicalRowThresholdTests {

    // MARK: - Harness

    private func root(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oplog-physical-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendRawLine(_ line: String, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func physicalLines(_ path: URL) -> Int {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Captures the process's stderr for the duration of `body`. The refusal
    /// warning IS the product behaviour under test — asserting on the feed
    /// alone cannot distinguish "the gate refused" from "the threshold was
    /// never reached", which is the whole of finding 2.
    private func capturingStderr(_ body: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        func restore() {
            dup2(saved, STDERR_FILENO)
            Darwin.close(saved)
            try? pipe.fileHandleForWriting.close()
        }
        do {
            try await body()
        } catch {
            restore()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
        restore()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try? pipe.fileHandleForReading.close()
        return text
    }

    // MARK: - 1. The raw scan reports physical rows

    @Test func readReportCountsEveryPhysicalLineIncludingUndecodableOnes() async throws {
        let dir = try root("report")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("feed.jsonl")
        let core = SwiftNativePersistenceCore()
        try await core.appendJSONL(.object(["a": .int(1)]), to: path)
        try appendRawLine("not json at all", to: path)
        try appendRawLine(#"{"op":"from_the_future"}"#, to: path)

        let (rows, report) = try await core.readJSONLReporting(path)
        #expect(rows.count == 2)                    // the two that PARSE
        #expect(report.malformedLineCount == 1)
        #expect(report.physicalLineCount == 3)      // what is actually on disk
        #expect(report.physicalLineCount == physicalLines(path))
    }

    // MARK: - 2. DeskStore: the refusal fires on a feed of undecodable rows

    /// A desk whose feed is mostly rows this build cannot decode is exactly the
    /// version-skew case. PRE-FIX: 3 decoded ops < the 8-row threshold, so
    /// compaction was never even considered and NOTHING was logged; the feed
    /// grew silently forever. POST-FIX: 33 physical rows ≥ 8 → the gate runs,
    /// refuses, and says so.
    @Test func deskThresholdCountsPhysicalRowsSoTheRefusalIsActuallyReached() async throws {
        let dir = try root("desk")
        defer { try? FileManager.default.removeItem(at: dir) }
        SnapshotTailOpLog.resetIntegrityLogMemoForTesting()
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)

        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "one")
        let second = try await store.createItem(kind: .plan, project: "NativeAgent", title: "two")

        // 30 rows a NEWER build wrote and this one has never heard of.
        for index in 0..<30 {
            try appendRawLine(
                #"{"opId":"future-\#(index)","ts":"2026-08-02T00:00:00.000000Z","op":"set_moon_phase","handle":"\#(second.handle)","phase":"waxing"}"#,
                to: store.opsPath
            )
        }
        let integrity = try await store.opLogIntegrity()
        #expect(integrity.undecodableRowCount == 30)
        #expect(integrity.physicalRowCount == 32)
        // The old number the threshold used to be compared against.
        #expect(integrity.feedRowCount(decodedCount: 2) == 32)

        let before = physicalLines(store.opsPath)
        let stderr = try await capturingStderr {
            _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "three")
        }

        #expect(stderr.contains("REFUSING to compact"))
        #expect(stderr.contains(store.opsPath.path))
        // …and nothing was destroyed: every row is still on disk.
        #expect(physicalLines(store.opsPath) == before + 1)
        let after = try await store.opLogIntegrity()
        #expect(after.undecodableRowCount == 30)
    }

    /// The worst skew: this build decodes NOTHING in the feed. The refusal must
    /// still fire — pre-fix the missing-lastOpId guard ran first and returned
    /// silently, so the loudest case was the quietest.
    @Test func deskRefusalFiresEvenWhenNoRowDecodesAtAll() async throws {
        let dir = try root("desk-all-future")
        defer { try? FileManager.default.removeItem(at: dir) }
        SnapshotTailOpLog.resetIntegrityLogMemoForTesting()
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 4)
        try FileManager.default.createDirectory(
            at: store.opsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: store.opsPath.path, contents: Data())
        for index in 0..<10 {
            try appendRawLine(
                #"{"opId":"future-\#(index)","ts":"2026-08-02T00:00:00.000000Z","op":"set_moon_phase","handle":"h1","phase":"waxing"}"#,
                to: store.opsPath
            )
        }

        // Nothing decodes, so the DECODED count — what the threshold used to
        // read — is 0 while the file holds 10 rows.
        let integrity = try await store.opLogIntegrity()
        let feed = DeskFeed(base: nil, ops: [], fileOpCount: 0, integrity: integrity)
        #expect(feed.fileOpCount == 0)
        #expect(feed.compactionRowCount == 10)

        let stderr = try await capturingStderr {
            _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "first decodable op")
        }
        #expect(stderr.contains("REFUSING to compact"))
    }

    // MARK: - 3. TaskLedger: same policy, same reachability

    @Test func taskLedgerThresholdCountsPhysicalRowsSoTheRefusalIsReached() async throws {
        let dir = try root("ledger")
        defer { try? FileManager.default.removeItem(at: dir) }
        SnapshotTailOpLog.resetIntegrityLogMemoForTesting()
        let ledger = SwiftNativeTaskLedger(dataRoot: dir, compactionThreshold: 8, keepTail: 2)

        _ = try await ledger.append(TaskLedgerEvent(taskId: "t1", actor: .claude, kind: .created, title: "one"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t1", actor: .claude, kind: .update, note: "two"))

        for index in 0..<25 {
            try appendRawLine(
                #"{"id":"future-\#(index)","taskId":"t1","ts":"2026-08-02T00:00:00.000000Z","actor":"claude","kind":"teleported"}"#,
                to: ledger.eventsPath
            )
        }
        let integrity = try await ledger.feedIntegrity()
        #expect(integrity.undecodableRowCount == 25)
        #expect(integrity.physicalRowCount == 27)

        let before = physicalLines(ledger.eventsPath)
        let stderr = try await capturingStderr {
            _ = try await ledger.append(
                TaskLedgerEvent(taskId: "t1", actor: .claude, kind: .update, note: "three")
            )
        }
        #expect(stderr.contains("REFUSING to compact"))
        #expect(physicalLines(ledger.eventsPath) == before + 1)
        #expect(try await ledger.feedIntegrity().undecodableRowCount == 25)
    }

    // MARK: - 4. GitHubCommandStore: malformed LINES count toward the threshold

    /// This store throws on an undecodable op, so its exposure is the malformed
    /// LINE that `readJSONL` drops silently. Padding the feed with those used to
    /// shrink the measured feed below the threshold.
    @Test func gitHubCommandThresholdCountsPhysicalRowsSoTheRefusalIsReached() async throws {
        let dir = try root("ghc")
        defer { try? FileManager.default.removeItem(at: dir) }
        SnapshotTailOpLog.resetIntegrityLogMemoForTesting()
        let store = GitHubCommandStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)

        let observation = GitHubCommandObservation(
            repository: "example/widgets", number: 11, kind: .pullRequest,
            title: "Repair widget 11", isOpen: true,
            observedVersion: "observed-1", actionableEventVersion: nil,
            signals: [], headSHA: "abc123", waitingKind: .review
        )
        _ = try await store.observe([observation])

        for index in 0..<20 {
            try appendRawLine("torn garbage row \(index) {", to: store.opsPath)
        }
        let integrity = try await store.opLogIntegrity()
        #expect(integrity.malformedLineCount == 20)
        #expect(integrity.physicalRowCount == 21)

        let before = physicalLines(store.opsPath)
        let stderr = try await capturingStderr {
            _ = try await store.observe([observation])
        }
        #expect(stderr.contains("REFUSING to compact"))
        #expect(physicalLines(store.opsPath) == before + 1)
    }

    // MARK: - 5. A clean feed still compacts, and replay is deterministic

    /// The threshold change must not weaken normal compaction. Drive a clean
    /// desk past the threshold, then REBUILD TWICE and compare: the compacted
    /// store must replay to exactly what an uncompacted store replays to, and
    /// to the same thing every time it is read.
    @Test func cleanFeedStillCompactsAndReplaysIdenticallyTwice() async throws {
        let compacting = try root("determinism-compacting")
        let control = try root("determinism-control")
        defer {
            try? FileManager.default.removeItem(at: compacting)
            try? FileManager.default.removeItem(at: control)
        }

        func fingerprint(_ state: DeskState) -> [String] {
            state.items
                .map { "\($0.alias)|\($0.kind.rawValue)|\($0.status.rawValue)|\($0.project)|\($0.title)" }
                .sorted()
        }
        func drive(_ store: SwiftNativeDeskStore) async throws {
            for index in 0..<12 {
                let item = try await store.createItem(
                    kind: .plan, project: "NativeAgent", title: "item \(index)"
                )
                if index % 3 == 0 {
                    _ = try await store.setStatus(item.handle, status: .now)
                }
            }
        }

        let store = SwiftNativeDeskStore(dataRoot: compacting, changeBus: StoreChangeBus(), opsCompactionThreshold: 6)
        let uncompacted = SwiftNativeDeskStore(dataRoot: control, changeBus: StoreChangeBus(), opsCompactionThreshold: 100_000)
        try await drive(store)
        try await drive(uncompacted)

        // Compaction genuinely ran: a base exists and the feed is far shorter
        // than the ops that produced it.
        #expect(FileManager.default.fileExists(atPath: store.basePath.path))
        #expect(physicalLines(store.opsPath) < physicalLines(uncompacted.opsPath))

        // Rebuild twice — same process, and again through a FRESH store object
        // that shares no in-memory state.
        let first = fingerprint(try await store.liveState())
        let second = fingerprint(try await store.liveState())
        let reopened = SwiftNativeDeskStore(dataRoot: compacting, changeBus: StoreChangeBus(), opsCompactionThreshold: 6)
        let third = fingerprint(try await reopened.liveState())
        #expect(first == second)
        #expect(first == third)
        #expect(first == fingerprint(try await uncompacted.liveState()))
    }

    // MARK: - 6. Finding 4 — a delegating conformer cannot report a false clean

    /// `DelegatingShim` is the exact mistake the review named: it implements
    /// `readJSONL` by delegating to the real file-backed core and never thinks
    /// about `readJSONLReporting`. PRE-FIX it inherited a hard-coded `.clean`,
    /// so a desk built on it compacted over rows it had skipped.
    @Test func aDelegatingConformerReportsTheFileHonestlyWithoutOverriding() async throws {
        let dir = try root("shim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("feed.jsonl")
        let shim = DelegatingShim()
        try await shim.appendJSONL(.object(["a": .int(1)]), to: path)
        try appendRawLine("}{ not json", to: path)
        try await shim.appendJSONL(.object(["a": .int(2)]), to: path)

        let (rows, report) = try await shim.readJSONLReporting(path)
        #expect(rows.count == 2)
        #expect(report.malformedLineCount == 1)    // pre-fix: 0
        #expect(report.physicalLineCount == 3)     // pre-fix: 0
        #expect(!report.isClean)
    }

    /// …and the consequence that matters: a store backed by that shim REFUSES
    /// to compact instead of erasing the row it could not read.
    @Test func aDeskOnADelegatingConformerRefusesToCompactOverASkippedRow() async throws {
        let dir = try root("shim-desk")
        defer { try? FileManager.default.removeItem(at: dir) }
        SnapshotTailOpLog.resetIntegrityLogMemoForTesting()
        let store = SwiftNativeDeskStore(
            dataRoot: dir, persistence: DelegatingShim(),
            changeBus: StoreChangeBus(), opsCompactionThreshold: 4
        )
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "one")
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "two")
        try appendRawLine("}{ a line a crashed writer left behind", to: store.opsPath)

        let before = physicalLines(store.opsPath)
        let stderr = try await capturingStderr {
            _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "three")
            _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "four")
        }
        #expect(stderr.contains("REFUSING to compact"))
        // The malformed row is still there — pre-fix the shim reported clean,
        // compaction ran, and the row was gone.
        #expect(physicalLines(store.opsPath) >= before)
        let text = try String(contentsOf: store.opsPath, encoding: .utf8)
        #expect(text.contains("a crashed writer left behind"))
    }

    // MARK: - 7. Finding 3 — the health value a Doctor check can render

    @Test func opLogHealthReportsBlockedWithTheFeedSize() async throws {
        let dir = try root("health")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwiftNativeDeskStore(dataRoot: dir, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "one")

        let healthy = try await store.opLogHealth()
        #expect(healthy.status == .ok)
        #expect(healthy.physicalRowCount == 1)
        #expect(healthy.byteCount > 0)

        try appendRawLine(#"{"opId":"f1","ts":"2026-08-02T00:00:00.000000Z","op":"set_moon_phase","handle":"h1"}"#, to: store.opsPath)
        let blocked = try await store.opLogHealth()
        #expect(blocked.status == .blocked)
        #expect(blocked.integrity.unusableRowCount == 1)
        #expect(blocked.physicalRowCount == 2)
        #expect(blocked.detailLine.contains("COMPACTION BLOCKED"))
    }

    /// Growth alone — nothing undecodable — is a WARNING, so an op-log that has
    /// stopped compacting for any other reason is still caught before it hurts.
    @Test func opLogHealthWarnsOnUnboundedGrowthWithNothingUndecodable() throws {
        let dir = try root("health-growth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ops.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: Data())
        let health = SnapshotTailOpLog.OpLogHealth(
            feed: "DeskStore", path: path,
            physicalRowCount: 8 * SnapshotTailOpLog.OpLogHealth.growthWarnMultiple,
            byteCount: 4096, compactionThreshold: 8, integrity: .clean
        )
        #expect(health.status == .warn)
        #expect(health.detailLine.contains("compaction threshold"))

        let normal = SnapshotTailOpLog.OpLogHealth(
            feed: "DeskStore", path: path,
            physicalRowCount: 9, byteCount: 512, compactionThreshold: 8, integrity: .clean
        )
        #expect(normal.status == .ok)
    }
}

/// A file-backed conformer that implements `readJSONL` by delegating and simply
/// never mentions `readJSONLReporting` — the shape finding 4 is about.
private struct DelegatingShim: PersistenceCoreProtocol {
    private let inner = SwiftNativePersistenceCore()

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await inner.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await inner.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await inner.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
    func replaceJSONL(_ records: [JSONValue], to path: URL) async throws {
        try await inner.replaceJSONL(records, to: path)
    }
    // NO readJSONLReporting. NO appendJSONLDurable. That is the point.
}
