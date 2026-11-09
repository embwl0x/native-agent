import CryptoKit
import Foundation
import Darwin

// Blueprint: | `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock`; inode-checked kernel locks and async acquisition. |

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

/// Serialize synchronous file transactions on the same sidecar as async acquisition.
public enum CredentialFileLock {
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
        return try FileLockScope.$heldLockPaths.withValue(FileLockScope.heldLockPaths.union([lockPath])) {
            try body()
        }
    }

    public static func withLock<T>(_ targetPath: URL, _ body: () throws -> T) throws -> T {
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
        guard flock(fd, LOCK_EX) == 0 else {
            let code = errno
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

public enum PersistenceFileLockWait {
    /// Bound acquisition so a stalled holder cannot hang the caller.
    public static let defaultSeconds: TimeInterval = 60
}

public extension SwiftNativePersistenceCore {
    /// Contended acquisition yields cooperatively; release completes synchronously with the body.
    /// - Parameter waitSeconds: maximum contention wait; `0` tries once and throws if busy.
    static func withFileLock<T: Sendable>(
        _ targetPath: URL,
        waitingAtMost waitSeconds: TimeInterval = PersistenceFileLockWait.defaultSeconds,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let lockPath = targetPath.path + ".lock"
        if FileLockScope.heldLockPaths.contains(lockPath) {
            return try await body()
        }
        let waitDeadline = ProcessInfo.processInfo.systemUptime + max(0, waitSeconds)
        let parent = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var attempts = 0
        while true {
            attempts += 1
            var fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            if fd < 0, errno == ENOENT {
                // Recreate a parent removed during acquisition; a second failure throws.
                try? FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true
                )
                fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
            }
            if fd < 0 {
                throw NSError(domain: "FileLock", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"])
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
                if try tryAcquireSidecar(fd) == 0 {
                    acquired = true
                    break
                }
                // Cancellation releases the descriptor through the iteration's defer.
                guard ProcessInfo.processInfo.systemUptime < waitDeadline else {
                    throw NSError(
                        domain: "FileLock", code: Int(ETIMEDOUT),
                        userInfo: [NSLocalizedDescriptionKey:
                            "lock at \(lockPath) stayed busy for \(Int(max(0, waitSeconds)))s; gave up rather than wait forever"])
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if try !sidecarIsCurrent(fd, at: lockPath) {
                // Bound retries when a sidecar is repeatedly replaced.
                if attempts >= 8 {
                    throw NSError(domain: "FileLock", code: Int(EAGAIN),
                        userInfo: [NSLocalizedDescriptionKey: "lock file at \(lockPath) replaced repeatedly; giving up after \(attempts) attempts"])
                }
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            keep = true
            defer {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
            return try await FileLockScope.$heldLockPaths.withValue(
                FileLockScope.heldLockPaths.union([lockPath])
            ) {
                try await body()
            }
        }
    }
}
