import Testing
import Foundation
@testable import PersistenceCore

/// Lock sidecars became reapable on 2026-07-25 (7159 orphan `*.json.lock`
/// against 2 live state files, oldest 2026-06-08). Unlinking a lock file is
/// safe ONLY under a precise contract, and these tests pin it:
///
///  1. A waiter that was already blocked on the unlinked inode must NOT run
///     concurrently with a newcomer that `O_CREAT`s a fresh one. This is what
///     `withFileLock`'s acquire-then-validate-inode step buys, and it is the
///     lost-write scenario Agent flagged.
///  2. The reaper must HOLD the lock and unlink as the LAST act inside it.
///     Measured 2026-07-25, not assumed: an earlier version of test 1 unlinked
///     the lock while a writer held it and lost an update (3 bumps -> count 2).
///     The inode check does not and cannot protect that case — a newcomer
///     arriving after the unlink creates a live file and legitimately locks it
///     while the old holder is still inside its body. So "unlink a lock file"
///     is unsafe in general; "unlink a lock file you hold, then immediately
///     stop" is safe, and only because the check rescues the waiters that were
///     blocked on the inode you just destroyed.
/// One-shot latch so the race tests stage phases by fact rather than by clock.
private actor Gate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

@Suite("FileLock reap safety")
struct FileLockReapSafetyTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filelock-reap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Non-atomic read-modify-write with a widened window: if two bodies ever
    /// overlap, one update is lost and the final count is short.
    private func bump(_ core: SwiftNativePersistenceCore, _ target: URL, _ counter: URL) async {
        try? await core.withFileLock(target) {
            let text = (try? String(contentsOf: counter, encoding: .utf8)) ?? "0"
            let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? Data("\(n + 1)".utf8).write(to: counter, options: .atomic)
        }
    }

    @Test func blockedWaiterDoesNotOverlapNewcomerAfterReap() async throws {
        let core = SwiftNativePersistenceCore()
        let root = try makeRoot()
        let target = root.appendingPathComponent("state.json")
        let lockPath = target.path + ".lock"
        let counter = root.appendingPathComponent("counter.txt")
        try Data("0".utf8).write(to: counter)

        await withTaskGroup(of: Void.self) { group in
            // A: holds the original inode for ~150ms.
            group.addTask { await self.bump(core, target, counter) }
            // B: arrives while A holds it, so it blocks on the ORIGINAL inode.
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000)
                await self.bump(core, target, counter)
            }
            // The reaper, using the sweep's REAL protocol: take the lock, and
            // unlink as the last act inside it. It therefore contends with A
            // and B rather than yanking a lock somebody holds.
            group.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000)
                try? await core.withFileLock(target) {
                    try? FileManager.default.removeItem(atPath: lockPath)
                }
            }
            // C: a newcomer that will find either the doomed inode or a fresh
            // one depending on timing. Whichever it gets, it must serialize.
            group.addTask {
                try? await Task.sleep(nanoseconds: 90_000_000)
                await self.bump(core, target, counter)
            }
        }

        let final = (try? String(contentsOf: counter, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(final == "3",
                "all three bodies must serialize despite the lock file being unlinked mid-flight (got \(final))")
    }

    /// The discriminating test for the inode check — this one fails against
    /// the pre-2026-07-25 lock (verified by stashing the fix: 3/3 runs lost an
    /// update, count 1 instead of 2). It stages the exact interleaving the
    /// sweep creates: the reaper holds the lock with a waiter already blocked
    /// on that inode, unlinks, and releases. The waiter then wakes holding a
    /// corpse while a newcomer owns the live file.
    ///
    /// The phase ordering is enforced by `Gate` rather than by sleeps (gpt-5.5
    /// review 2026-07-25: a purely sleep-staged version can pass vacuously on a
    /// loaded machine by never reaching the intended interleaving). B is
    /// released only once the reaper provably holds the lock, and C only once
    /// the unlink has provably happened.
    @Test func waiterOnAReapedInodeMustNotOverlapTheNewcomer() async throws {
        let core = SwiftNativePersistenceCore()
        let root = try makeRoot()
        let target = root.appendingPathComponent("state.json")
        let lockPath = target.path + ".lock"
        let counter = root.appendingPathComponent("counter.txt")
        try Data("0".utf8).write(to: counter)

        let held = Gate()
        let unlinked = Gate()

        await withTaskGroup(of: Void.self) { group in
            // The reaper, exactly as sweepOrphansIfDue behaves: hold the lock,
            // unlink as the last act inside it.
            group.addTask {
                try? await core.withFileLock(target) {
                    await held.open()
                    // Give B time to reach flock() on this (doomed) inode.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    try? FileManager.default.removeItem(atPath: lockPath)
                    await unlinked.open()
                }
            }
            // B: starts only once the reaper holds the lock, so it is
            // guaranteed to block on the inode about to be destroyed.
            group.addTask {
                await held.wait()
                await self.bump(core, target, counter)
            }
            // C: starts only after the unlink, so it creates and owns a FRESH
            // inode. Without the check, B wakes on the corpse and runs its
            // read-modify-write straight through C's.
            group.addTask {
                await unlinked.wait()
                await self.bump(core, target, counter)
            }
        }

        let final = (try? String(contentsOf: counter, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(final == "2",
                "the waiter must re-acquire the live lock file rather than run on the reaped inode (got \(final))")
    }

    @Test func lockIsReacquirableAfterItsFileIsRemoved() async throws {
        let core = SwiftNativePersistenceCore()
        let root = try makeRoot()
        let target = root.appendingPathComponent("state.json")
        let lockPath = target.path + ".lock"

        let ran = try await core.withFileLock(target) { true }
        #expect(ran)
        #expect(FileManager.default.fileExists(atPath: lockPath))

        // Reaped while idle — the next acquisition must simply re-create it.
        try FileManager.default.removeItem(atPath: lockPath)
        let ranAgain = try await core.withFileLock(target) { true }
        #expect(ranAgain)
        #expect(FileManager.default.fileExists(atPath: lockPath))
    }

    /// Deliberately narrow: `withFileLock` does not expose its fd, so a test
    /// cannot compare the held inode against the path from out here. This
    /// asserts only the weaker, still-useful property that a lock file exists
    /// at the path for the duration of the body — the full inode-identity
    /// contract is what `waiterOnAReapedInodeMustNotOverlapTheNewcomer` pins,
    /// and that is the test which actually discriminates the fix (gpt-5.5
    /// review 2026-07-25: the previous name over-claimed what this checks).
    @Test func aLockFileExistsAtThePathForTheDurationOfTheBody() async throws {
        let core = SwiftNativePersistenceCore()
        let root = try makeRoot()
        let target = root.appendingPathComponent("state.json")
        let lockPath = target.path + ".lock"

        try await core.withFileLock(target) {
            var atPath = stat()
            #expect(stat(lockPath, &atPath) == 0, "the locked file must still exist at the path")
        }
    }
}
