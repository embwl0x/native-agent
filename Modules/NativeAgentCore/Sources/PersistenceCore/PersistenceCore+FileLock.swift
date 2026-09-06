import CryptoKit
import Foundation
import Darwin

/// Lock paths the CURRENT TASK already holds. User, 2026-09-06: `flock` is not
/// recursive across descriptors, so a `CredentialFileLock.withLock` nested
/// inside a `withFileLock` on the SAME path — which is what every credential
/// write through `writeJSONObject` does from inside a `withFileLock` body —
/// sat out the full acquire timeout and then threw. Both acquirers record
/// their lock path here, and the synchronous one (always the inner
/// acquisition) skips the `flock` when this task already holds that path.
public enum FileLockScope {
    @TaskLocal public static var heldLockPaths: Set<String> = []
}

/// User, 2026-09-06: an OAuth credential file has THREE writers — an adapter's
/// token refresh, the app's sign-in, and the app's sign-out — and none of them
/// shared a lock. Every writer therefore compared the file's bytes and then
/// wrote, with the whole race window between the two: a sign-out that landed
/// in that gap was undone by the refresh it was meant to cancel. This is the
/// SAME `flock` on the SAME `<path>.lock` sidecar that `withFileLock` below
/// takes, in a synchronous shape so the compare and the write it guards sit in
/// one critical section on every path — including the app's, which is not
/// async.
///
/// The body must stay short: it reads and rewrites one small credential file
/// and never performs I/O of its own. Nothing inside it may await.
public enum CredentialFileLock {
    /// Longest a caller waits for the holder before giving up. The critical
    /// sections are a read plus an atomic rename; a wait this long means the
    /// lock is held by something wedged, and failing beats hanging a turn.
    private static let acquireTimeout: TimeInterval = 10

    public static func withLock<T>(_ targetPath: URL, _ body: () throws -> T) throws -> T {
        let lockPath = targetPath.path + ".lock"
        // Already held by this task (an enclosing `withFileLock` on the same
        // path): the critical section is ours, and a second `flock` on a second
        // descriptor would only block until the timeout.
        if FileLockScope.heldLockPaths.contains(lockPath) {
            return try body()
        }
        let parent = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(acquireTimeout)
        var attempts = 0
        while true {
            attempts += 1
            let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0 {
                throw NSError(domain: "FileLock", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"])
            }
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
                let e = errno
                if e == EINTR { continue }
                if e != EWOULDBLOCK {
                    Darwin.close(fd)
                    throw NSError(domain: "FileLock", code: Int(e), userInfo: [NSLocalizedDescriptionKey: "flock LOCK_EX failed: \(String(cString: strerror(e)))"])
                }
                if Date() >= deadline {
                    Darwin.close(fd)
                    throw NSError(domain: "FileLock", code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "lock at \(lockPath) is still held after \(Int(acquireTimeout))s"])
                }
                usleep(5_000)
            }
            // Same acquire-then-validate-inode rule as `withFileLock`: the
            // orphan sweep may unlink a lock sidecar, and a waiter that opened
            // it before the unlink would otherwise hold a detached inode while
            // a newcomer creates a fresh one — two writers, no exclusion.
            var held = stat()
            var atPath = stat()
            let sameInode = fstat(fd, &held) == 0
                && stat(lockPath, &atPath) == 0
                && held.st_dev == atPath.st_dev
                && held.st_ino == atPath.st_ino
            if !sameInode {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
                if attempts >= 8 {
                    throw NSError(domain: "FileLock", code: Int(EAGAIN), userInfo: [NSLocalizedDescriptionKey: "lock file at \(lockPath) replaced repeatedly; giving up after \(attempts) attempts"])
                }
                usleep(5_000)
                continue
            }
            defer {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
            return try FileLockScope.$heldLockPaths.withValue(
                FileLockScope.heldLockPaths.union([lockPath])
            ) {
                try body()
            }
        }
    }

    /// User, 2026-09-06: the generation of an OAuth credential file — a digest
    /// of ONLY the token-bearing keys. The whole file's bytes used to be the
    /// generation, but provider settings share the file with the credential
    /// (`configureProvider` writes `default_model` into
    /// `providers/<id>.json`, which is exactly where the Anthropic and xAI
    /// credentials live). Saving a model while a refresh was in flight moved
    /// the bytes, the refresh read that as "another writer replaced the
    /// credential", and it dropped the token it had just minted — leaving the
    /// already-rotated, single-use refresh_token on disk to fail next time.
    /// Only a change to the tokens themselves counts as a new generation.
    /// The digest never contains a credential, so it is safe to carry around.
    public static func credentialGeneration(ofFileAt path: URL) -> String {
        credentialGeneration(ofFileContents: try? Data(contentsOf: path))
    }

    public static func credentialGeneration(ofFileContents data: Data?) -> String {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "absent" }
        let nested = (obj["tokens"] as? [String: Any]) ?? [:]
        let fields = ["access_token", "refresh_token", "id_token", "account_id"]
            .map { key -> String in
                let value = (obj[key] as? String) ?? (nested[key] as? String) ?? ""
                return "\(key)=\(value)"
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(fields.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

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
        // cross-process flock semantics are unchanged (same lock file, same
        // LOCK_EX).
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
            var fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0, errno == ENOENT {
                // 2026-09-06: the parent directory went away between the
                // createDirectory above and this open — an orphan sweep can
                // unlink a per-session directory a writer is about to use
                // (TurnVolatileArchive). Recreate it and try once more; a
                // second ENOENT is a real failure and throws below.
                try? FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true
                )
                fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            }
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
            // Record the held path so a synchronous `CredentialFileLock` inside
            // the body does not try to take the same non-recursive flock again.
            return try await FileLockScope.$heldLockPaths.withValue(
                FileLockScope.heldLockPaths.union([lockPath])
            ) {
                try await body()
            }
        }
    }
}
