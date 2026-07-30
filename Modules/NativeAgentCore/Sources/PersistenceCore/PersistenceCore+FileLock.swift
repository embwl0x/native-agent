import Foundation
import Darwin

public extension PersistenceCoreProtocol {
    func withFileLock<T: Sendable>(_ targetPath: URL, _ body: @Sendable () async throws -> T) async throws -> T {
        let lockPath = targetPath.path + ".lock"
        let parent = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // Acquire WITHOUT pinning a cooperative-pool thread. The old shape —
        // blocking flock(LOCK_EX) inside Task.detached, unlock in ANOTHER
        // detached task fired from defer — could freeze the whole app: N
        // concurrent waiters (N = core count) occupy every pool thread in
        // flock() while the holder's detached unlock task waits for a free
        // thread that never comes (audit 2026-06-09, both auditors).
        // LOCK_NB + cancellable async sleep keeps threads free, and the
        // synchronous release means the lock drops the instant body ends —
        // cross-process flock semantics with the daemon's file_lock.py are
        // unchanged (same lock file, same LOCK_EX).
        // Acquire-then-validate-inode (2026-07-25). Lock sidecars are now
        // REAPABLE (the orphan sweep unlinks them), and unlinking a lock file
        // is only safe if acquirers notice they locked a detached inode:
        // otherwise a waiter that opened the file before the unlink wakes up
        // holding a dead inode while a newcomer O_CREATs a fresh one — two
        // writers, mutual exclusion silently gone (Agent, 2026-07-25). After
        // flock succeeds we compare our fd's inode against whatever is at
        // lockPath now; a mismatch means we hold a corpse, so we drop it and
        // retry against the live file. This is the standard resolution of the
        // unlink-a-lockfile race and is what makes the sweep safe.
        var attempts = 0
        while true {
            attempts += 1
            let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0 {
                throw NSError(domain: "FileLock", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"])
            }
            var acquired = false
            var keep = false
            defer {
                if !keep {
                    if acquired { _ = flock(fd, LOCK_UN) }
                    Darwin.close(fd)
                }
            }
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    acquired = true
                    break
                }
                let e = errno
                if e != EWOULDBLOCK && e != EINTR {
                    throw NSError(domain: "FileLock", code: Int(e), userInfo: [NSLocalizedDescriptionKey: "flock LOCK_EX failed: \(String(cString: strerror(e)))"])
                }
                // Contended: yield the thread and retry. Cancellation propagates
                // (Task.sleep throws), releasing the fd via the defer above.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            // Do we hold the file that is CURRENTLY at lockPath?
            var held = stat()
            var atPath = stat()
            let sameInode = fstat(fd, &held) == 0
                && stat(lockPath, &atPath) == 0
                && held.st_dev == atPath.st_dev
                && held.st_ino == atPath.st_ino
            if !sameInode {
                // Reaped or replaced under us. Bounded retry: a live sweep can
                // legitimately unlink once, but repeated misses mean something
                // pathological, and spinning forever would be worse than
                // failing loudly.
                if attempts >= 8 {
                    throw NSError(domain: "FileLock", code: Int(EAGAIN), userInfo: [NSLocalizedDescriptionKey: "lock file at \(lockPath) replaced repeatedly; giving up after \(attempts) attempts"])
                }
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            keep = true
            defer {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
            return try await body()
        }
    }
}
