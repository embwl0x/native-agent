import CryptoKit
import Foundation
import Darwin
import NativeAgentCore
import Synchronization

// Blueprint: | `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock`; inode-checked kernel locks, async acquisition, the holder's life |

/// Task-local held paths let nested acquisitions reuse the same nonrecursive flock.
public enum FileLockScope {
    @TaskLocal public static var heldLockPaths: Set<String> = []
}

public enum FileLockError: LocalizedError, CustomNSError {
    case busy(path: String)
    case sidecarReplaced(path: String)
    case notRegularFile(path: String)
    case posix(operation: String, path: String, code: Int32)
    case cancelled

    public static let errorDomain = "FileLock"

    public var errorCode: Int {
        switch self {
        case .busy: Int(ETIMEDOUT)
        case .sidecarReplaced: Int(EAGAIN)
        case .notRegularFile: Int(EINVAL)
        case .posix(_, _, let code): Int(code)
        case .cancelled: Int(ECANCELED)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .busy(let path): "Lock at \(path) is busy."
        case .sidecarReplaced(let path): "Lock file at \(path) changed during acquisition. Repair the owner replacing it."
        case .notRegularFile(let path): "Lock at \(path) is not a regular file."
        case .posix(let operation, let path, let code): "\(operation) failed at \(path): \(unsafe String(cString: strerror(code)))"
        case .cancelled: "The file lock wait was cancelled."
        }
    }
}

private func openSidecar(at path: String, flags: Int32) throws(FileLockError) -> OwnedFD {
    guard let fd = OwnedFD(raw: unsafe Darwin.open(path, flags | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)) else { throw .posix(operation: "Open lock", path: path, code: errno) }
    return fd
}

private func tryAcquireSidecar(_ fd: Int32, at path: String) throws(FileLockError) -> Bool {
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
    let code = errno
    guard code == EWOULDBLOCK else { throw .posix(operation: "flock LOCK_EX", path: path, code: code) }
    return false
}

private func sidecarIsCurrent(_ fd: Int32, at path: String) throws(FileLockError) -> Bool {
    var held = stat()
    var atPath = stat()
    guard unsafe fstat(fd, &held) == 0, unsafe lstat(path, &atPath) == 0 else {
        throw .posix(operation: "Read lock identity", path: path, code: errno)
    }
    guard (held.st_mode & S_IFMT) == S_IFREG else { throw .notRegularFile(path: path) }
    return held.st_dev == atPath.st_dev && held.st_ino == atPath.st_ino
}

/// The holder names itself in the sidecar, so a waiter can ask whether the process holding the lock still runs.
private func markHolder(_ fd: Int32) {
    let pid = Array("\(getpid())\n".utf8)
    if ftruncate(fd, 0) == 0 { _ = unsafe pid.withUnsafeBytes { unsafe pwrite(fd, $0.baseAddress, $0.count, 0) } }
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
        let descriptor = try openSidecar(at: lockPath, flags: O_WRONLY)
        let fd = descriptor.raw
        guard try tryAcquireSidecar(fd, at: lockPath) else { return nil }
        defer { _ = flock(fd, LOCK_UN) }
        guard try sidecarIsCurrent(fd, at: lockPath) else {
            throw FileLockError.sidecarReplaced(path: lockPath)
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
        let descriptor = try openSidecar(at: lockPath, flags: O_RDWR)
        let fd = descriptor.raw
        let watched = life.map { ($0, $0.attach(holderLife(targetPath))) }
        let locked = flock(fd, LOCK_EX)
        let code = errno
        if case let (watch, id)? = watched { watch.detach(id) }
        guard locked == 0 else {
            throw FileLockError.posix(operation: "flock LOCK_EX", path: lockPath, code: code)
        }
        defer { _ = flock(fd, LOCK_UN) }
        guard try sidecarIsCurrent(fd, at: lockPath) else {
            throw FileLockError.sidecarReplaced(path: lockPath)
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw FileLockError.posix(operation: "Secure lock permissions", path: lockPath, code: errno)
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

/// One wait for a busy sidecar: a thread of its own blocks in `flock` while the caller awaits. Whichever side leaves first decides who
/// releases: a caller resumed with the lock owns the descriptor; a caller that left (Stop) hands it to the thread, which releases the lock
/// the moment it gets it.
private final class SidecarWait: Sendable {
    private typealias Waiter = CheckedContinuation<Result<Void, FileLockError>, Never>
    private struct State: ~Copyable {
        var fd: OwnedFD?
        var waiter: Waiter?
        var left = false
    }

    private let path: String
    private let state: Mutex<State>

    init(_ fd: consuming OwnedFD, at path: String) {
        state = Mutex(State(fd: consume fd))
        self.path = path
    }

    func acquire() async throws(FileLockError) -> OwnedFD {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { start($0) }
        } onCancel: { leave() }
        try result.get()
        return state.withLock { $0.fd.take()! }
    }

    private func start(_ continuation: Waiter) {
        let leftAlready = state.withLock { state in
            if !state.left { state.waiter = continuation }
            return state.left
        }
        guard !leftAlready else {
            state.withLock { $0.fd = nil }
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        let thread = Thread { [self] in block() }
        thread.name = "file lock wait"
        thread.start()
    }

    private func leave() {
        let waiting = state.withLock { state in
            state.left = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiting?.resume(returning: .failure(.cancelled))
    }

    private func block() {
        let fd = state.withLock { $0.fd?.raw }!
        var locked = flock(fd, LOCK_EX)
        while locked != 0, errno == EINTR { locked = flock(fd, LOCK_EX) }
        let code = errno
        let waiting = state.withLock { state in
            defer { state.waiter = nil }
            if locked != 0 || state.waiter == nil {
                if locked == 0 { _ = flock(fd, LOCK_UN) }
                state.fd = nil
            }
            return state.waiter
        }
        guard let waiting else { return }
        guard locked == 0 else {
            waiting.resume(returning: .failure(.posix(operation: "flock LOCK_EX", path: path, code: code)))
            return
        }
        waiting.resume(returning: .success(()))
    }
}

public extension SwiftNativePersistenceCore {
    /// Hold the target's sidecar lock for `body`; release completes with the body. A busy lock is waited for in a blocking `flock` on a
    /// thread of its own, never the cooperative pool: the kernel releases a dead holder's lock, so the wait lasts only while its holder
    /// lives, and the caller's Stop ends it at once. `life`, the watch of the call waiting, is shown the holder while it waits.
    /// - Parameter tryingOnce: take the lock only if it is free; busy throws `ETIMEDOUT` in the `FileLock` domain.
    @concurrent static func withFileLock<T: Sendable>(
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
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var attempts = 0
        while true {
            attempts += 1
            let opened: OwnedFD
            do {
                opened = try openSidecar(at: lockPath, flags: O_WRONLY)
            } catch FileLockError.posix(_, _, ENOENT) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                opened = try openSidecar(at: lockPath, flags: O_WRONLY)
            }
            let held: OwnedFD
            if try !tryAcquireSidecar(opened.raw, at: lockPath) {
                guard !tryingOnce else { throw FileLockError.busy(path: lockPath) }
                let wait = SidecarWait(consume opened, at: lockPath)
                let watched = life.map { ($0, $0.attach(CredentialFileLock.holderLife(targetPath))) }
                defer { if case let (watch, id)? = watched { watch.detach(id) } }
                do { held = try await wait.acquire() }
                catch FileLockError.cancelled { throw CancellationError() }
            } else { held = consume opened }
            let fd = held.raw
            defer { _ = flock(fd, LOCK_UN) }
            guard try sidecarIsCurrent(fd, at: lockPath) else {
                if attempts >= 8 {
                    throw FileLockError.sidecarReplaced(path: lockPath)
                }
                continue
            }
            markHolder(fd)
            return try await FileLockScope.$heldLockPaths.withValue(FileLockScope.heldLockPaths.union([lockPath])) {
                try await body()
            }
        }
    }
}
