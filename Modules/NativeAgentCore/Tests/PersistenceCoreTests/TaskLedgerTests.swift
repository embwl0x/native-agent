import XCTest
import Foundation
@testable import PersistenceCore
import NativeAgentTestSupport

// MARK: - Cross-agent task ledger tests (U6 orchestration polish)
//
// Covers: append/list/claim round-trip, derived-state compaction, the
// newest-5000 cap, stale-claim detection, and — the correctness-critical one —
// CROSS-PROCESS flock parity: a spawned Swift helper process and the in-Swift
// SwiftNativeTaskLedger.append serialize on the SAME
// `<feed>.lock` sidecar with no torn lines. Mirrors FileLockTests conventions.

final class TaskLedgerTests: XCTestCase {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskledger-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: append / list round-trip

    func test_append_then_list_roundtrip() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)

        let created = try await ledger.append(TaskLedgerEvent(
            taskId: "T1", actor: .claude, kind: .created, title: "Wire the ledger"
        ))
        XCTAssertEqual(created.taskId, "T1")

        let tasks = try await ledger.listTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].taskId, "T1")
        XCTAssertEqual(tasks[0].title, "Wire the ledger")
        XCTAssertEqual(tasks[0].status, .created)
        XCTAssertNil(tasks[0].owner)

        // Events feed + derived state file both exist on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.eventsPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.statePath.path))
    }

    // MARK: claim sets owner; compaction folds the stream

    func test_claim_sets_owner_and_status_folds() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)

        _ = try await ledger.append(TaskLedgerEvent(taskId: "T2", actor: .user, kind: .created, title: "Fix bug"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "T2", actor: .codex, kind: .claimed))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "T2", actor: .codex, kind: .update, note: "halfway", refs: ["file.swift"]))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "T2", actor: .codex, kind: .done))

        let tasks = try await ledger.listTasks(includeTerminal: true)
        let t2 = try XCTUnwrap(tasks.first { $0.taskId == "T2" })
        XCTAssertEqual(t2.owner, .codex)        // last claimer
        XCTAssertEqual(t2.status, .done)         // last kind
        XCTAssertEqual(t2.title, "Fix bug")      // seeded by created
        XCTAssertEqual(t2.lastNote, "halfway")   // note persists past kinds without notes
        XCTAssertEqual(t2.refs, ["file.swift"])

        // includeTerminal:false hides done tasks.
        let open = try await ledger.listTasks(includeTerminal: false)
        XCTAssertFalse(open.contains { $0.taskId == "T2" })
    }

    // MARK: cap — newest-5000

    func test_cap_trims_to_keep_tail_with_hysteresis() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)

        // Write past the threshold directly to the events file to avoid 5001 recompactions.
        let persistence = SwiftNativePersistenceCore()
        for i in 0..<(SwiftNativeTaskLedger.maxLines + 10) {
            let e = TaskLedgerEvent(taskId: "bulk-\(i)", actor: .claude, kind: .created, title: "t\(i)")
            try await persistence.appendJSONL(e.toJSON(), to: ledger.eventsPath)
        }
        // One more append through the ledger triggers the compaction.
        _ = try await ledger.append(TaskLedgerEvent(taskId: "final", actor: .assistant, kind: .created))

        let lines = try String(contentsOf: ledger.eventsPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        // Hysteresis (audit 2026-07-21): the feed trims to the threshold/4
        // keep-tail, NOT back up to the threshold, so the next 3/4·threshold
        // appends don't each rewrite base + full feed.
        XCTAssertEqual(lines.count, SwiftNativeTaskLedger.compactionKeepTail,
                       "feed should trim to keep-tail \(SwiftNativeTaskLedger.compactionKeepTail), got \(lines.count)")
        // The newest event survived; the oldest folded into the base.
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("\"final\""))
        XCTAssertFalse(text.contains("\"bulk-0\""))
    }

    // MARK: B4 — snapshot+tail: founding events survive compaction

    /// The correctness-critical B4 case: a quiet task whose founding events
    /// (title + owner) would scroll off the newest-N cap must NOT vanish. With
    /// snapshot+tail those events fold into the base and the task still lists.
    func test_founding_events_survive_compaction_via_base() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Small trim so a handful of events exercise the snapshot+tail path.
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 8, keepTail: 4)

        // Oldest events: the founder's title + owner. These land in the prefix
        // that compaction folds into the base.
        _ = try await ledger.append(TaskLedgerEvent(taskId: "founder", actor: .user, kind: .created, title: "Founding"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "founder", actor: .codex, kind: .claimed))
        // Six newer events for other tasks push the founder past the kept tail;
        // the 8th append crosses the threshold and triggers compaction.
        for i in 0..<6 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "bulk-\(i)", actor: .claude, kind: .created, title: "b\(i)"))
        }

        // Base was written; the feed file was trimmed below the raw total.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.basePath.path),
                      "compaction should have written the base snapshot")
        let feedLines = try String(contentsOf: ledger.eventsPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(feedLines.count, 4, "feed should trim to keepTail")
        // The founder's raw events were folded out of the feed file…
        XCTAssertFalse(feedLines.joined(separator: "\n").contains("\"founder\""),
                       "founder events should have folded into the base, not the tail")

        // …yet the task still lists WITH its title and owner (the B4 guarantee).
        let tasks = try await ledger.listTasks()
        let founder = try XCTUnwrap(tasks.first { $0.taskId == "founder" },
                                    "quiet founding task must not vanish after compaction")
        XCTAssertEqual(founder.title, "Founding")
        XCTAssertEqual(founder.owner, .codex)
        XCTAssertEqual(founder.status, .claimed)
    }

    /// A tail event on a COMPACTED task must still fold on top of the base state.
    func test_tail_event_updates_compacted_task_over_base() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 6, keepTail: 3)

        _ = try await ledger.append(TaskLedgerEvent(taskId: "quiet", actor: .user, kind: .created, title: "Quiet"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "quiet", actor: .codex, kind: .claimed))
        // Push "quiet" into the base.
        for i in 0..<4 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "noise-\(i)", actor: .claude, kind: .created))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.basePath.path))

        // Now advance the compacted task via a fresh tail event.
        _ = try await ledger.append(TaskLedgerEvent(taskId: "quiet", actor: .codex, kind: .done, note: "shipped"))
        let afterTail = try await ledger.listTasks()
        let quiet = try XCTUnwrap(afterTail.first { $0.taskId == "quiet" })
        XCTAssertEqual(quiet.status, .done, "tail event must fold on top of the base state")
        XCTAssertEqual(quiet.owner, .codex, "owner from the compacted base must persist")
        XCTAssertEqual(quiet.title, "Quiet")
        XCTAssertEqual(quiet.lastNote, "shipped")
    }

    /// An old feed with NO base file must load as pure genesis (additive on disk).
    func test_missing_base_loads_as_genesis() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        let persistence = SwiftNativePersistenceCore()
        // Seed the feed directly, no base file — the pre-B4 on-disk shape.
        _ = try await persistence.appendJSONL(
            TaskLedgerEvent(taskId: "legacy", actor: .user, kind: .created, title: "Legacy").toJSON(),
            to: ledger.eventsPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.basePath.path))

        let tasks = try await ledger.listTasks()
        XCTAssertEqual(tasks.first?.taskId, "legacy")
        XCTAssertEqual(tasks.first?.title, "Legacy")
    }

    /// A base file that EXISTS but does not decode must fail LOUD, never fold
    /// from the tail alone (which would silently blank every compacted task).
    func test_corrupt_base_throws() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        _ = try await ledger.append(TaskLedgerEvent(taskId: "x", actor: .user, kind: .created, title: "x"))
        try Data("{\"not\":\"a base\"}".utf8).write(to: ledger.basePath)
        do {
            _ = try await ledger.listTasks()
            XCTFail("a corrupt base must throw, not fold from the tail alone")
        } catch is TaskLedgerBaseCorrupt {
            // expected
        }
    }

    // MARK: stale claims

    func test_stale_claims_detected_after_threshold() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)

        // A claim 30h ago, never updated → stale.
        let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-30 * 3600))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "stale", ts: old, actor: .codex, kind: .claimed, title: "Old claim"))
        // A claim 1h ago → not stale.
        let recent = TaskLedgerClock.nowISO(Date().addingTimeInterval(-3600))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "fresh", ts: recent, actor: .claude, kind: .claimed, title: "Fresh claim"))

        // NOTE: each append recompacts state and the events keep their ts.
        let stale = try await ledger.staleClaims(staleAfter: 24 * 3600)
        XCTAssertEqual(stale.map(\.taskId), ["stale"])
    }

    func test_stale_claim_cleared_by_update() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)

        let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-30 * 3600))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "T", ts: old, actor: .codex, kind: .claimed, title: "x"))
        // A recent update advances updatedTs and changes status away from claimed.
        _ = try await ledger.append(TaskLedgerEvent(taskId: "T", actor: .codex, kind: .update, note: "still going"))

        let stale = try await ledger.staleClaims(staleAfter: 24 * 3600)
        XCTAssertTrue(stale.isEmpty, "an update should clear the stale-claim signal")
    }

    // MARK: CROSS-PROCESS lock parity (Swift writer + Swift helper process)
    //
    // Proves the in-Swift withFileLock and a separate helper process flock on the
    // SAME `<feed>.lock` sidecar serialize: the helper holds the lock for
    // 250ms; the Swift append must BLOCK until it releases (no torn lines, both
    // events present). Mirrors FileLockTests' cross-process recipe.

    func test_cross_process_lock_with_external_helper_no_torn_lines() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        let feed = ledger.eventsPath
        try? FileManager.default.createDirectory(
            atPath: (feed.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        // External child flocks the exact sidecar the Swift side uses, holds it
        // briefly, then appends one well-formed JSONL line under the lock.
        let acquiredMarker = feed.deletingLastPathComponent()
            .appendingPathComponent("helper_acquired.txt")
        let proc = try NativeAgentFlockChild.appendAfterHold(
            lockPath: feed.path + ".lock",
            target: feed,
            acquiredMarker: acquiredMarker,
            line: #"{"actor": "codex", "id": "swift-helper", "kind": "created", "taskId": "SWIFT_HELPER", "ts": "2026-01-01T00:00:00.000000+00:00"}"# + "\n",
            holdSeconds: 0.5
        )
        defer { proc.terminate() }

        // Wait for the helper to signal it holds the lock.
        let gotLocked = NativeAgentFlockChild.waitForFile(acquiredMarker, timeout: 10)
        XCTAssertTrue(gotLocked, "flock helper failed to acquire the lock")
        guard gotLocked else { return }

        // Swift append must block on the helper-held lock, so elapsed >= ~180ms.
        let start = Date()
        _ = try await ledger.append(TaskLedgerEvent(taskId: "SWIFT", actor: .assistant, kind: .created))
        let elapsed = Date().timeIntervalSince(start)
        let status = proc.wait(timeout: 10.0)
        XCTAssertNotNil(status, "flock helper failed to exit within 10s of releasing")
        XCTAssertEqual(status, 0)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            0.150,
            "Swift acquired before helper released; lock sidecar mismatch; elapsed=\(elapsed)"
        )

        // Both writers' lines landed, every line is well-formed JSON (no torn lines).
        let lines = try String(contentsOf: feed, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)),
                             "torn / malformed line: \(line)")
        }
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("\"SWIFT_HELPER\""), "helper event missing")
        XCTAssertTrue(joined.contains("\"SWIFT\""), "swift event missing")
    }

    // MARK: state file shape the Swift CLI writer must also produce

    func test_state_file_envelope_shape() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        _ = try await ledger.append(TaskLedgerEvent(taskId: "S", actor: .user, kind: .created, title: "z"))

        let data = try Data(contentsOf: ledger.statePath)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["version"] as? Int, 1)
        XCTAssertNotNil(obj["generatedTs"])
        let tasks = try XCTUnwrap(obj["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.first?["taskId"] as? String, "S")
    }
}
