import CryptoKit
import Foundation
import Darwin
import NativeAgentCore

// Blueprint: | `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock`; inode-checked kernel locks, async acquisition, the holder's life |

/// Task-local held paths let nested acquisitions reuse the same nonrecursive flock.
public enum FileLockScope {
    @TaskLocal public static var heldLockPaths: Set<String> = []
}

private func tryAcquireSidecar(_ fd: Int32) throws -> Int32 {
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return 0 }
    let error = errno
    guard error == EWOULDBLOCK else {
        throw NSError(domain: "FileLock", code: Int(error), userInfo: [NSLocalizedDescriptionKey: "flock LOCK_EX failed: \(String(cString: strerror(error)))"])
    }
    return error
}

/// Enter a locked body only if the descriptor still names the sidecar at its path.
private func sidecarIsCurrent(_ fd: Int32, at path: String) throws -> Bool {
    var held = stat()
    var atPath = stat()
    guard fstat(fd, &held) == 0, lstat(path, &atPath) == 0 else {
        let code = errno
        throw NSError(domain: "FileLock", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
            "Cannot read lock identity at \(path): \(String(cString: strerror(code)))"])
    }
    return held.st_dev == atPath.st_dev && held.st_ino == atPath.st_ino
}

/// The holder names itself in the sidecar, so a waiter can ask whether the process holding the lock still runs.
private func markHolder(_ fd: Int32) {
    let pid = Array("\(getpid())\n".utf8)
    if ftruncate(fd, 0) == 0 { _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } }
}

/// Serialize synchronous file transactions on the same sidecar as async acquisition.
public enum CredentialFileLock {
    /// What a call waiting for this lock waits on: the process holding it, as the holder named itself in the sidecar. Alive while that other
    /// process runs; held in this process, or by a holder that named nothing, it cannot say.
    public static func holderLife(_ targetPath: URL) -> CallLife {
        let lockPath = targetPath.path + ".lock"
        return CallLife(what: "the process holding the lock on \(targetPath.lastPathComponent)") {
            guard let named = try? String(contentsOfFile: lockPath, encoding: .utf8),
                  let pid = pid_t(named.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, pid != getpid() else { return .unknown }
            return kill(pid, 0) == 0 || errno == EPERM ? .alive : .unknown
        }
    }

    /// One attempt; contention defers the transaction, while unreadable or replaced lock identity throws.
    public static func tryWithLock<T>(_ targetPath: URL, _ body: () throws -> T) throws -> T? {
        let lockPath = targetPath.path + ".lock"
        if FileLockScope.heldLockPaths.contains(lockPath) { return try body() }
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "FileLock", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"])
        }
        defer { Darwin.close(fd) }
        guard try tryAcquireSidecar(fd) == 0 else { return nil }
        defer { _ = flock(fd, LOCK_UN) }
        guard try sidecarIsCurrent(fd, at: lockPath) else {
            throw NSError(domain: "FileLock", code: Int(EAGAIN), userInfo: [NSLocalizedDescriptionKey:
                "Lock file at \(lockPath) changed during acquisition; repair its replacing owner."])
        }
        markHolder(fd)
        return try FileLockScope.$heldLockPaths.withValue(FileLockScope.heldLockPaths.union([lockPath])) {
            try body()
        }
    }

    /// `life` is the watch of the call waiting for the lock: while it waits, the holder is what it waits on.
    public static func withLock<T>(_ targetPath: URL, life: TurnDeadline? = nil, _ body: () throws -> T) throws -> T {
        let lockPath = targetPath.path + ".lock"
        if FileLockScope.heldLockPaths.contains(lockPath) {
            return try body()
        }
        let parent = (lockPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw NSError(domain: "FileLock", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"])
        }
        let watched = life.map { ($0, $0.attach(holderLife(targetPath))) }
        let locked = flock(fd, LOCK_EX)
        let code = errno
        if case let (watch, id)? = watched { watch.detach(id) }
        guard locked == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "FileLock", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
                "flock LOCK_EX failed at \(lockPath): \(String(cString: strerror(code)))"])
        }
        defer {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        guard try sidecarIsCurrent(fd, at: lockPath) else {
            throw NSError(domain: "FileLock", code: Int(EAGAIN), userInfo: [NSLocalizedDescriptionKey:
                "Lock file at \(lockPath) changed during acquisition; repair its replacing owner."])
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "FileLock", code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey:
                "lock at \(lockPath) is not a regular file"])
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw NSError(domain: "FileLock", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "secure lock permissions failed: \(String(cString: strerror(errno)))"])
        }
        markHolder(fd)
        return try FileLockScope.$heldLockPaths.withValue(FileLockScope.heldLockPaths.union([lockPath])) {
            try body()
        }
    }

    /// Credential generation hashes only token and account-identity fields, excluding provider settings.
    public static func credentialGeneration(ofFileContents data: Data?) -> String {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "absent" }
        let nested = (obj["tokens"] as? [String: Any]) ?? [:]
        let fields = ["access_token", "refresh_token", "id_token", "account_id",
                      "oauth_account_identity", "refresh_token_account_identity"]
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

private func releaseSidecar(_ fd: Int32) {
    _ = flock(fd, LOCK_UN)
    Darwin.close(fd)
}

/// One wait for a busy sidecar: a thread of its own blocks in `flock` while the caller awaits. Whichever side leaves first decides who
/// releases: a caller resumed with the lock owns the descriptor; a caller that left (Stop) hands it to the thread, which releases the lock
/// the moment it gets it.
private final class SidecarWait: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Error>?
    private var left = false

    init(_ fd: Int32) { self.fd = fd }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        let leftAlready = lock.withLock { () -> Bool in
            if !left { waiter = continuation }
            return left
        }
        guard !leftAlready else {
            Darwin.close(fd)
            continuation.resume(throwing: CancellationError())
            return
        }
        let thread = Thread { [self] in block() }
        thread.name = "file lock wait"
        thread.start()
    }

    /// The caller stops waiting at once; the descriptor is the thread's from here.
    func leave() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            left = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(throwing: CancellationError())
    }

    private func block() {
        var locked = flock(fd, LOCK_EX)
        while locked != 0, errno == EINTR { locked = flock(fd, LOCK_EX) }
        let code = errno
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { waiter = nil }
            return waiter
        }
        guard let waiting, locked == 0 else {
            // The caller left, or the wait failed: nothing here keeps the lock or the descriptor.
            if locked == 0 { _ = flock(fd, LOCK_UN) }
            Darwin.close(fd)
            waiting?.resume(throwing: NSError(domain: "FileLock", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
                "flock LOCK_EX failed: \(String(cString: strerror(code)))"]))
            return
        }
        waiting.resume()
    }
}

public extension SwiftNativePersistenceCore {
    /// Hold the target's sidecar lock for `body`; release completes with the body. A busy lock is waited for in a blocking `flock` on a
    /// thread of its own, never the cooperative pool: the kernel releases a dead holder's lock, so the wait lasts only while its holder
    /// lives, and the caller's Stop ends it at once. `life`, the watch of the call waiting, is shown the holder while it waits.
    /// - Parameter tryingOnce: take the lock only if it is free; busy throws `ETIMEDOUT` in the `FileLock` domain.
    static func withFileLock<T: Sendable>(
        _ targetPath: URL,
        tryingOnce: Bool = false,
        life: TurnDeadline? = nil,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let lockPath = targetPath.path + ".lock"
        if FileLockScope.heldLockPaths.contains(lockPath) {
            return try await body()
        }
        let parent = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var attempts = 0
        while true {
            attempts += 1
            var fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0, errno == ENOENT {
                // Recreate a parent removed during acquisition; a second failure throws.
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            }
            if fd < 0 {
                throw NSError(domain: "FileLock", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"])
            }
            let busy: Bool
            do { busy = try tryAcquireSidecar(fd) != 0 } catch { Darwin.close(fd); throw error }
            if busy {
                guard !tryingOnce else {
                    Darwin.close(fd)
                    throw NSError(domain: "FileLock", code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "lock at \(lockPath) is busy"])
                }
                let wait = SidecarWait(fd)
                let watched = life.map { ($0, $0.attach(CredentialFileLock.holderLife(targetPath))) }
                defer { if case let (watch, id)? = watched { watch.detach(id) } }
                // A wait that throws has already given up the descriptor.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { wait.start($0) }
                } onCancel: { wait.leave() }
            }
            let current: Bool
            do { current = try sidecarIsCurrent(fd, at: lockPath) } catch { releaseSidecar(fd); throw error }
            guard current else {
                // The sidecar was replaced while held: lock the one now at the path.
                releaseSidecar(fd)
                if attempts >= 8 {
                    throw NSError(domain: "FileLock", code: Int(EAGAIN),
                        userInfo: [NSLocalizedDescriptionKey: "lock file at \(lockPath) replaced repeatedly; giving up after \(attempts) attempts"])
                }
                continue
            }
            defer { releaseSidecar(fd) }
            markHolder(fd)
            return try await FileLockScope.$heldLockPaths.withValue(FileLockScope.heldLockPaths.union([lockPath])) {
                try await body()
            }
        }
    }
}
