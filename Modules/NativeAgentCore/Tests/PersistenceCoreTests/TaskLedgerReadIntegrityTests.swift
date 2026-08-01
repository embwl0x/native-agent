import Foundation
import Darwin
import Testing
@testable import PersistenceCore

// MARK: - TaskLedger read integrity (audit 2026-08-01)
//
// Three defects pinned here:
//   1. LOCK-FREE READERS COULD DOUBLE-APPLY A COMPACTED PREFIX. `listTasks` /
//      `staleClaims` read events FIRST and the base SECOND with no lock and —
//      unlike GitHubCommandStore — no `tailFirstOpId` torn-read proof. A reader
//      suspended at the await between the two reads pairs a PRE-compaction
//      events snapshot with a POST-compaction base; `dropCompactedPrefix` finds
//      no `lastCompactedOpId` in the stale snapshot, returns the events
//      unchanged, and the fold replays events the base already contains — a
//      `done` task reappears as `claimed` and `staleClaims` fires on it. The
//      fix takes the events flock across BOTH reads, so the pairing can never
//      exist. The race itself is not schedulable from a test; what IS testable
//      (and is the whole fix) is that the read path holds the lock.
//   2. readJSON's default-on-ANY-failure laundered a transient IO error into
//      the permanent "base is corrupt" invariant.
//   3. Compaction-base retention keyed on wall-clock `Date()`, so the same feed
//      folded differently depending on when the append ran.
//
// Swift Testing (not XCTest) so these run under the `--disable-xctest` gate.

@Suite("TaskLedger: read integrity + base failure classification")
struct TaskLedgerReadIntegrityTests {
    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskledger-readintegrity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run `body` with a deadline; nil means it never finished in time.
    private func withDeadline<T: Sendable>(
        nanoseconds: UInt64,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: 1 — the read path holds the events flock

    @Test("listTasks reads base+tail under the events flock (no torn compaction pairing)")
    func listTasksTakesTheEventsFlock() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t1", actor: .claude, kind: .created, title: "one"))

        // Hold the SAME cross-process lock sidecar `withFileLock` uses. flock is
        // per open-file-description, so this blocks even in-process.
        let lockPath = ledger.eventsPath.path + ".lock"
        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)

        let blocked = await withDeadline(nanoseconds: 1_500_000_000) { () -> Bool? in
            _ = try? await ledger.listTasks()
            return true
        }
        #expect(blocked == nil, "listTasks completed while the events flock was held — it is reading lock-free and can pair a stale events snapshot with a post-compaction base")

        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)

        // Lock released: the same read now completes promptly.
        let after = await withDeadline(nanoseconds: 10_000_000_000) { () -> [TaskLedgerTaskState]? in
            try? await ledger.listTasks()
        }
        #expect(after??.count == 1)
    }

    @Test("staleClaims does not nest the (non-reentrant) events flock")
    func staleClaimsDoesNotDeadlock() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-48 * 3600))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t1", ts: old, actor: .user, kind: .created, title: "one"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t1", ts: old, actor: .codex, kind: .claimed))

        // withFileLock is NOT reentrant: if staleClaims took the lock itself on
        // top of listTasks' lock it would spin EWOULDBLOCK against itself
        // forever. Bound the await so a regression fails instead of hanging.
        let stale = await withDeadline(nanoseconds: 10_000_000_000) { () -> [TaskLedgerTaskState]? in
            try? await ledger.staleClaims(staleAfter: 24 * 3600)
        }
        #expect(stale??.count == 1, "staleClaims deadlocked or returned nothing")
    }

    @Test("a compacted base + a stale full feed folds each event exactly once")
    func compactedFeedDoesNotDoubleApply() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 6, keepTail: 2)

        _ = try await ledger.append(TaskLedgerEvent(taskId: "a", actor: .user, kind: .created, title: "alpha", refs: ["r1"]))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "a", actor: .codex, kind: .claimed))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "a", actor: .codex, kind: .done, refs: ["r2"]))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "b", actor: .user, kind: .created, title: "beta"))
        _ = try await ledger.append(TaskLedgerEvent(taskId: "b", actor: .claude, kind: .claimed))

        // Snapshot the FULL pre-compaction feed, then cross the threshold.
        let fullFeed = try String(contentsOf: ledger.eventsPath, encoding: .utf8)
        _ = try await ledger.append(TaskLedgerEvent(taskId: "c", actor: .user, kind: .created, title: "gamma"))
        #expect(FileManager.default.fileExists(atPath: ledger.basePath.path))

        let compacted = try await ledger.listTasks()

        // Reinstate the pre-compaction feed alongside the new base — exactly
        // the crash window between base write and feed truncate, and the same
        // (stale feed, new base) shape a racing reader used to observe. The
        // prefix-drop must fold each event exactly once.
        let lastLine = try String(contentsOf: ledger.eventsPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        try (fullFeed + lastLine + "\n").write(to: ledger.eventsPath, atomically: true, encoding: .utf8)

        let healed = try await ledger.listTasks()
        #expect(healed.count == compacted.count)
        let a = healed.first { $0.taskId == "a" }
        #expect(a?.status == .done, "a done task must not be resurrected by a replayed prefix")
        #expect(a?.owner == .codex)
        #expect(a?.refs == ["r1", "r2"], "refs union double-applied")
        #expect(healed.first { $0.taskId == "b" }?.status == .claimed)
        #expect(healed.first { $0.taskId == "c" }?.status == .created)

        // And the stale-claim signal must not fire on the closed task.
        let stale = try await ledger.staleClaims(staleAfter: 0)
        #expect(!stale.contains { $0.taskId == "a" }, "staleClaims fired on a task the base already folded to done")
    }

    // MARK: 2 — transient IO must not be laundered into permanent corruption

    @Test("an unreadable-but-present base throws transient, not corrupt")
    func unreadableBaseIsTransientNotCorrupt() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 4, keepTail: 1)
        for i in 0..<4 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "t\(i)", actor: .claude, kind: .created))
        }
        #expect(FileManager.default.fileExists(atPath: ledger.basePath.path))

        // A path that EXISTS but whose bytes cannot be read — the same shape
        // readJSON used to swallow into its `.null` default (EMFILE burst, an
        // iCloud dataless placeholder, a mid-read EIO).
        try FileManager.default.removeItem(at: ledger.basePath)
        try FileManager.default.createDirectory(at: ledger.basePath, withIntermediateDirectories: true)

        var thrown: (any Error)?
        do { _ = try await ledger.listTasks() } catch { thrown = error }
        #expect(thrown is TaskLedgerBaseUnreadable,
                "a transient IO failure was reported as permanent corruption: \(String(describing: thrown))")
    }

    @Test("a base whose bytes ARE readable but do not parse still fails loud as corrupt")
    func garbageBaseStillFailsLoud() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 4, keepTail: 1)
        for i in 0..<4 {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "t\(i)", actor: .claude, kind: .created))
        }
        try Data("{not json".utf8).write(to: ledger.basePath)

        var thrown: (any Error)?
        do { _ = try await ledger.listTasks() } catch { thrown = error }
        #expect(thrown is TaskLedgerBaseCorrupt,
                "genuine corruption must still fail loud: \(String(describing: thrown))")
    }

    // MARK: 3 — deterministic retention + bounded refs

    @Test("compaction retention anchors to the feed's own newest stamp, not wall clock")
    func retentionAnchorsToFeedStamp() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root, compactionThreshold: 6, keepTail: 2)
        // EVERY event is 60 days old. Wall-clock retention would evict the
        // terminal task; feed-anchored retention (newest stamp == 60d ago)
        // keeps it, so the same feed always folds to the same base.
        let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-60 * 24 * 3600))
        for i in 0..<6 {
            let kind: TaskLedgerKind = i == 1 ? .done : .created
            let taskId = i <= 1 ? "old-done" : "t\(i)"
            _ = try await ledger.append(TaskLedgerEvent(taskId: taskId, ts: old, actor: .codex, kind: kind))
        }
        let baseRaw = try String(contentsOf: ledger.basePath, encoding: .utf8)
        #expect(baseRaw.contains("old-done"),
                "retention used wall-clock time — an all-old feed folded differently than it will on replay")
    }

    @Test("the derived refs union is bounded")
    func refsUnionIsCapped() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SwiftNativeTaskLedger(dataRoot: root)
        _ = try await ledger.append(TaskLedgerEvent(taskId: "t", actor: .user, kind: .created, title: "t"))
        for i in 0..<(SwiftNativeTaskLedger.maxRefsPerTask + 20) {
            _ = try await ledger.append(TaskLedgerEvent(taskId: "t", actor: .claude, kind: .update, refs: ["ref-\(i)"]))
        }
        let task = try await ledger.listTasks().first { $0.taskId == "t" }
        #expect(task?.refs.count == SwiftNativeTaskLedger.maxRefsPerTask)
        #expect(task?.refs.last == "ref-\(SwiftNativeTaskLedger.maxRefsPerTask + 19)", "cap must keep the NEWEST refs")
    }
}
