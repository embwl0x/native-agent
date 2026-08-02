import Foundation
import Darwin
import Testing
@testable import PersistenceCore

/// `appendJSONLDurable` must never report success when the flush FAILED
/// (gpt-5.5 review 2026-08-02, BLOCKING 1).
///
/// THE BUG THESE PIN: the durability tail ran inside a NON-THROWING `defer` —
/// `if durable, fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }` — so a failed
/// `F_FULLFSYNC` fell back to `fsync` whose result was DISCARDED, and `close`'s
/// result was discarded too. `write` succeeding was therefore the only thing
/// the caller ever learned about. On a dying disk (EIO) or a full one (ENOSPC)
/// the op-log stores went on to write derived state and to COMPACT — deleting
/// the old copy of data whose new copy was never durable. That is the exact
/// loss the durable path exists to prevent.
///
/// Every test below drives the real code through an injected syscall seam and
/// FAILS on the pre-fix implementation, which could not throw from any of these
/// paths: it returned success for all of them.
@Suite("Durable append flush failures")
struct DurableAppendFlushTests {

    // MARK: - Harness

    /// A real file + descriptor, so the code under test operates on a genuine
    /// fd while the FLUSH syscalls are faked.
    private final class Fixture: @unchecked Sendable {
        let path: URL
        let fd: Int32
        private var realFDOpen = true

        init(_ tag: String) throws {
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("durable-flush-\(tag)-\(UUID().uuidString).jsonl")
            FileManager.default.createFile(atPath: path.path, contents: Data("{}\n".utf8))
            fd = open(path.path, O_WRONLY | O_APPEND)
            #expect(fd >= 0)
        }

        /// The fake `close` still closes the real descriptor (so the test leaks
        /// nothing) but reports whatever errno the case is exercising.
        func closingFake(reporting errno: Int32) -> @Sendable (Int32) -> Int32 {
            { [weak self] fd in
                _ = Darwin.close(fd)
                self?.realFDOpen = false
                return errno
            }
        }

        deinit {
            if realFDOpen { _ = Darwin.close(fd) }
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Counts what each syscall was asked to do.
    private final class Calls: @unchecked Sendable {
        var fullFsync = 0
        var fsync = 0
        var close = 0
    }

    // MARK: - 1. A real flush failure THROWS (and does not "fall back")

    /// `F_FULLFSYNC` failing with EIO is the disk saying the data is not on it.
    /// PRE-FIX: swallowed in the defer, `appendJSONLDurable` returned success.
    @Test func fullFsyncIOFailureThrowsAndDoesNotFallBackToFsync() throws {
        let fixture = try Fixture("eio")
        let calls = Calls()
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in calls.fullFsync += 1; return EIO },
            fsync: { _ in calls.fsync += 1; return 0 },
            close: fixture.closingFake(reporting: 0)
        )

        #expect(throws: PersistenceCoreError.self) {
            try SwiftNativePersistenceCore.flushAndClose(
                fd: fixture.fd, path: fixture.path, durable: true, syscalls: syscalls
            )
        }
        #expect(calls.fullFsync == 1)
        // Falling back here would ask the SAME broken device again and let a
        // lost write pass as a commit. Fallback is for "unsupported", only.
        #expect(calls.fsync == 0)
    }

    // MARK: - 2. The fallback's own failure THROWS

    /// The named failure case from the review: `F_FULLFSYNC` unsupported, the
    /// fallback `fsync` then fails with ENOSPC. PRE-FIX: `_ = fsync(fd)`
    /// discarded exactly this.
    @Test func unsupportedFullFsyncWithFailingFsyncThrows() throws {
        let fixture = try Fixture("nospc")
        let calls = Calls()
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in calls.fullFsync += 1; return ENOTSUP },
            fsync: { _ in calls.fsync += 1; return ENOSPC },
            close: fixture.closingFake(reporting: 0)
        )

        #expect(throws: PersistenceCoreError.self) {
            try SwiftNativePersistenceCore.flushAndClose(
                fd: fixture.fd, path: fixture.path, durable: true, syscalls: syscalls
            )
        }
        #expect(calls.fullFsync == 1)
        #expect(calls.fsync == 1)
    }

    // MARK: - 3. The legitimate degrade still SUCCEEDS

    /// A filesystem with no drive-cache flush (some network/virtual volumes)
    /// must keep working: unsupported → plain fsync → success, no throw.
    @Test func unsupportedFullFsyncFallsBackToASucceedingFsync() throws {
        let fixture = try Fixture("degrade")
        let calls = Calls()
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in calls.fullFsync += 1; return EOPNOTSUPP },
            fsync: { _ in calls.fsync += 1; return 0 },
            close: fixture.closingFake(reporting: 0)
        )

        try SwiftNativePersistenceCore.flushAndClose(
            fd: fixture.fd, path: fixture.path, durable: true, syscalls: syscalls
        )
        #expect(calls.fullFsync == 1)
        #expect(calls.fsync == 1)
    }

    // MARK: - 4. EINTR is retried, not treated as a durability failure

    @Test func fullFsyncRetriesOnEINTRAndThenSucceeds() throws {
        let fixture = try Fixture("eintr")
        let calls = Calls()
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in
                calls.fullFsync += 1
                return calls.fullFsync < 3 ? EINTR : 0
            },
            fsync: { _ in calls.fsync += 1; return 0 },
            close: fixture.closingFake(reporting: 0)
        )

        try SwiftNativePersistenceCore.flushAndClose(
            fd: fixture.fd, path: fixture.path, durable: true, syscalls: syscalls
        )
        #expect(calls.fullFsync == 3)
        #expect(calls.fsync == 0)   // never degraded — EINTR is not "unsupported"
    }

    // MARK: - 5. A failed close throws on the durable path

    /// On a writeback filesystem close(2) is where a deferred write error
    /// surfaces. PRE-FIX the return value was dropped on the floor.
    @Test func failedCloseThrowsWhenDurable() throws {
        let fixture = try Fixture("close-eio")
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in 0 },
            fsync: { _ in 0 },
            close: fixture.closingFake(reporting: EIO)
        )

        #expect(throws: PersistenceCoreError.self) {
            try SwiftNativePersistenceCore.flushAndClose(
                fd: fixture.fd, path: fixture.path, durable: true, syscalls: syscalls
            )
        }
    }

    /// …but the NON-durable fast path (telemetry, turn traces) keeps its
    /// historical best-effort contract rather than starting to throw.
    @Test func failedCloseDoesNotThrowOnTheNonDurablePath() throws {
        let fixture = try Fixture("close-lenient")
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in Issue.record("must not flush on the non-durable path"); return 0 },
            fsync: { _ in Issue.record("must not flush on the non-durable path"); return 0 },
            close: fixture.closingFake(reporting: EIO)
        )

        try SwiftNativePersistenceCore.flushAndClose(
            fd: fixture.fd, path: fixture.path, durable: false, syscalls: syscalls
        )
    }

    // MARK: - 6. The descriptor is closed EXACTLY once, even when flush throws

    /// A leak here would be silent and unbounded — the durable path is the one
    /// every canonical op takes.
    @Test func descriptorIsClosedExactlyOnceWhenTheFlushFails() throws {
        let fixture = try Fixture("close-once")
        let calls = Calls()
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in EIO },
            fsync: { _ in 0 },
            close: { fd in
                calls.close += 1
                _ = Darwin.close(fd)
                return 0
            }
        )

        #expect(throws: PersistenceCoreError.self) {
            try SwiftNativePersistenceCore.flushAndClose(
                fd: fixture.fd, path: fixture.path, durable: true, syscalls: syscalls
            )
        }
        #expect(calls.close == 1)
    }

    // MARK: - 7. End to end through the real append path

    /// The whole point: a durable APPEND whose flush fails must surface as a
    /// thrown error to the store that called it, so it never goes on to write
    /// derived state or compact.
    @Test func appendBytesDurableThrowsWhenTheFlushFails() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-append-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let syscalls = SwiftNativePersistenceCore.FlushSyscalls(
            fullFsync: { _ in EIO },
            fsync: { _ in 0 },
            close: { fd in _ = Darwin.close(fd); return 0 }
        )

        #expect(throws: PersistenceCoreError.self) {
            try SwiftNativePersistenceCore.appendBytes(
                Data("{\"op\":\"x\"}\n".utf8), to: path, durable: true, syscalls: syscalls
            )
        }
        // The bytes DID reach the page cache — the throw is about durability,
        // not about the write. The caller's job is to stop trusting the op,
        // which is precisely what it could not do before.
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        #expect(text.contains("\"op\":\"x\""))
    }

    /// The normal path still works end to end with the real syscalls: an
    /// `appendJSONLDurable` lands the row and returns cleanly.
    @Test func realDurableAppendStillSucceeds() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-real-\(UUID().uuidString)")
            .appendingPathComponent("feed.jsonl")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let core = SwiftNativePersistenceCore()
        try await core.appendJSONLDurable(.object(["a": .int(1)]), to: path)
        try await core.appendJSONLDurable(.object(["a": .int(2)]), to: path)
        let rows = try await core.readJSONL(path)
        #expect(rows.count == 2)
    }
}
