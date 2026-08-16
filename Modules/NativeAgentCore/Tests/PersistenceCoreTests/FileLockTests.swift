import XCTest
import Foundation
@testable import PersistenceCore
import NativeAgentTestSupport

final class FileLockTests: XCTestCase {
    private func tmpFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filelock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func test_withFileLock_runs_body_and_returns_value() async throws {
        let core = SwiftNativePersistenceCore()
        let target = tmpFile("a.txt")
        let result: Int = try await core.withFileLock(target) { 42 }
        XCTAssertEqual(result, 42)
    }

    func test_withFileLock_concurrent_callers_serialize() async throws {
        let core = SwiftNativePersistenceCore()
        let target = tmpFile("serialize.txt")
        FileManager.default.createFile(atPath: target.path, contents: Data())

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try? await core.withFileLock(target) {
                        let handle = try FileHandle(forWritingTo: target)
                        try handle.seekToEnd()
                        let existing = (try? Data(contentsOf: target)) ?? Data()
                        let combined = existing + Data("line-\(i)\n".utf8)
                        try combined.write(to: target)
                        try handle.close()
                    }
                }
            }
        }

        let contents = try String(contentsOf: target, encoding: .utf8)
        for i in 0..<8 {
            XCTAssertTrue(contents.contains("line-\(i)"), "missing line-\(i) in: \(contents)")
        }
    }

    /// Tracks how many lock bodies are inside their critical section at once, so
    /// a body can await the OTHER's arrival instead of guessing at a clock.
    private actor OccupancyGate {
        private var inside = 0
        private var peak = 0
        func enter() { inside += 1; peak = max(peak, inside) }
        func exit() { inside -= 1 }
        /// Poll `peak`, never `inside`: occupancy is transient, and whichever
        /// body notices the overlap first will have left by the time the other
        /// polls. `peak` is monotonic, so both bodies observe the overlap that
        /// actually happened. (Polling `inside` made this test deadlock-by-race
        /// against itself — the second body exited before the first looked.)
        func peakOccupancy() -> Int { peak }
    }

    /// M16 (2026-07-09): this assertion used to be `elapsed < 0.380` around two
    /// 200ms sleeps — a 180ms wall-clock margin, and THE genuine flake in this
    /// suite: under parallel load a perfectly correct, fully-overlapping pair
    /// still blew the budget. The property under test is not "fast", it is
    /// "these two critical sections OVERLAP" — holding the lock on `a` must not
    /// exclude the lock on `b`. That is structural, so assert it structurally:
    /// each body announces its arrival and waits for the other before leaving.
    /// A serializing implementation leaves the first body waiting alone until the
    /// deadline and the test fails loudly (it never hangs). Passing no longer
    /// depends on speed, so the deadline can be generous.
    func test_withFileLock_different_paths_dont_block() async throws {
        let core = SwiftNativePersistenceCore()
        let a = tmpFile("a.txt")
        let b = tmpFile("b.txt")
        let gate = OccupancyGate()
        let deadline = Date().addingTimeInterval(20)

        @Sendable func awaitBothInside() async -> Bool {
            await gate.enter()
            var sawBoth = false
            while Date() < deadline {
                if await gate.peakOccupancy() >= 2 { sawBoth = true; break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            await gate.exit()
            return sawBoth
        }

        async let r1: Bool = core.withFileLock(a) { await awaitBothInside() }
        async let r2: Bool = core.withFileLock(b) { await awaitBothInside() }
        let (first, second) = try await (r1, r2)

        XCTAssertTrue(first, "lock on a.txt was blocked by the lock on b.txt")
        XCTAssertTrue(second, "lock on b.txt was blocked by the lock on a.txt")
        let peak = await gate.peakOccupancy()
        XCTAssertEqual(peak, 2, "different paths must hold their locks concurrently; peak occupancy=\(peak)")
    }

    func test_withFileLock_throws_propagate_and_release() async throws {
        let core = SwiftNativePersistenceCore()
        let target = tmpFile("err.txt")
        struct Boom: Error {}
        do {
            try await core.withFileLock(target) { throw Boom() }
            XCTFail("expected throw")
        } catch is Boom {}
        // lock should be released — re-acquire quickly
        let acquired = try await core.withFileLock(target) { true }
        XCTAssertTrue(acquired)
    }

    func test_withFileLock_cross_process_serialization_via_external_helper() async throws {
        let core = SwiftNativePersistenceCore()
        let target = tmpFile("xproc.txt")
        let lockPath = target.path + ".lock"
        // parent dir for lock
        try? FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // External child uses flock(2) on the same sidecar. Readiness uses a
        // marker file instead of stdout so the wait is actually bounded.
        let acquiredMarker = target.deletingLastPathComponent()
            .appendingPathComponent("helper_acquired.txt")
        let proc = try NativeAgentFlockChild.hold(
            lockPath: lockPath,
            acquiredMarker: acquiredMarker,
            holdSeconds: 0.5
        )
        defer { proc.terminate() }

        // wait until the helper signals it has the lock
        let gotLocked = NativeAgentFlockChild.waitForFile(acquiredMarker, timeout: 10.0)
        XCTAssertTrue(gotLocked, "flock helper failed to acquire lock")
        guard gotLocked else { return }

        let start = Date()
        try await core.withFileLock(target) {}
        let elapsed = Date().timeIntervalSince(start)
        let status = proc.wait(timeout: 10.0)
        XCTAssertNotNil(status, "flock helper failed to exit within 10s of releasing")
        XCTAssertEqual(status, 0)
        XCTAssertGreaterThanOrEqual(elapsed, 0.180, "swift acquired before helper released; elapsed=\(elapsed)")
    }

    func test_withFileLock_lock_file_created_with_0o600_perms() async throws {
        let core = SwiftNativePersistenceCore()
        let target = tmpFile("perm.txt")
        try await core.withFileLock(target) {}
        let lockPath = target.path + ".lock"
        let attrs = try FileManager.default.attributesOfItem(atPath: lockPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "lock file perms = \(String(perms, radix: 8))")
    }

    // MARK: - BUG-B regression
    //
    // Regression shape: a read-modify-write owner and a peer appender target
    // the same JSONL file. Without flock around the RMW, a
    // concurrent writer that lands between our read and our atomic-replace gets
    // its rows silently truncated. This test models that race: the
    // "recaller" deletes id=A under a lock; a "daemon" writer concurrently
    // appends a new line under the SAME lock convention (path + ".lock").
    // With the lock both writers see each other's results; without it,
    // one trash-cans the other.
    func test_BUG_B_recaller_remove_under_lock_no_rows_lost_with_concurrent_writer() async throws {
        let core = SwiftNativePersistenceCore()
        let target = tmpFile("memory_embeddings.jsonl")
        try? FileManager.default.createDirectory(atPath: (target.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // Seed file with 3 records (matching recaller's wire format).
        let seed = """
        {"id":"A","text":"alpha","embedding":[1.0]}
        {"id":"B","text":"beta","embedding":[2.0]}
        {"id":"C","text":"gamma","embedding":[3.0]}

        """
        try Data(seed.utf8).write(to: target)

        await withTaskGroup(of: Void.self) { group in
            // Writer 1: delete id=A under the lock: read all,
            // filter out matching id, rewrite atomically — all under flock).
            group.addTask {
                try? await core.withFileLock(target) {
                    let bytes = (try? Data(contentsOf: target)) ?? Data()
                    let text = String(data: bytes, encoding: .utf8) ?? ""
                    let kept = text.split(separator: "\n").filter { !$0.contains("\"id\":\"A\"") }
                    let out = kept.joined(separator: "\n") + "\n"
                    // Inject a small delay inside the lock to maximize the
                    // race window — without the lock, the daemon writer's
                    // append below races our atomic-replace and one of the
                    // two writes is lost. With the lock, the daemon writer
                    // blocks until we're done.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    try Data(out.utf8).write(to: target, options: .atomic)
                }
            }
            // Writer 2: append a new record under the same lock convention
            // (`<path>.lock` sibling).
            group.addTask {
                try? await core.withFileLock(target) {
                    let bytes = (try? Data(contentsOf: target)) ?? Data()
                    let appended = bytes + Data("{\"id\":\"D\",\"text\":\"delta\",\"embedding\":[4.0]}\n".utf8)
                    try appended.write(to: target, options: .atomic)
                }
            }
        }

        let finalText = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        // Result must contain B, C, D (and NOT A). If the lock failed,
        // one writer's effect would be missing.
        XCTAssertFalse(finalText.contains("\"id\":\"A\""), "id=A should be removed")
        XCTAssertTrue(finalText.contains("\"id\":\"B\""), "id=B lost — recaller rewrite raced appender")
        XCTAssertTrue(finalText.contains("\"id\":\"C\""), "id=C lost — recaller rewrite raced appender")
        XCTAssertTrue(finalText.contains("\"id\":\"D\""), "id=D lost — appender raced recaller rewrite")
    }
}
