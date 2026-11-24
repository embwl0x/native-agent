import CryptoKit
import Darwin
import Foundation
import NativeAgentCore

// Blueprint: | `CheckedFixedSizeSecretFile.swift` | `CheckedFixedSizeSecretFile`; Missing-only creation; invalid bytes preserved. |

@safe private struct SecretBytes<let N: Int>: ~Copyable {
    let buffer: UnsafeMutableRawBufferPointer

    static func withStorage<Result>(_ body: (borrowing Self) throws -> Result) rethrows -> Result {
        var storage = InlineArray<N, UInt8>(repeating: 0)
        return try withUnsafeMutableBytes(of: &storage) { buffer in
            let secret = unsafe Self(buffer: buffer)
            return try body(secret)
        }
    }

    deinit {
        _ = unsafe memset_s(buffer.baseAddress!, N, 0, N)
    }
}

/// Callers own authority lifecycle; only missing state may bootstrap, and existing invalid bytes remain unavailable and untouched.
public enum CheckedFixedSizeSecretFile {
    public struct Unavailable: Error, LocalizedError, Sendable {
        public let path: String
        public let detail: String

        public init(path: String, detail: String) {
            self.path = path
            self.detail = detail
        }

        public var errorDescription: String? {
            "Secret state unavailable at \(path): \(detail)"
        }
    }

    /// Serialize missing-only creation and exact reads; fsync, permission-check and read back the same descriptor before publication.
    public static func loadOrCreate(at url: URL) throws(Unavailable) -> SymmetricKey {
        return try checked(at: url) { try CredentialFileLock.withLock(url) {
            let parent = url.deletingLastPathComponent()
            switch targetKind(at: url) {
            case .missing:
                return try createAndVerify(SymmetricKey(size: .bits256), at: url, parent: parent)

            case .existing:
                return try readAndVerify(at: url)

            case .unavailable(let detail):
                throw Unavailable(path: url.path, detail: detail)
            }
        } }
    }

    /// Every failure of a public operation reaches its caller as Unavailable, naming the file.
    private static func checked<T>(at url: URL, _ access: () throws -> T) throws(Unavailable) -> T {
        do { return try access() }
        catch let unavailable as Unavailable { throw unavailable }
        catch { throw Unavailable(path: url.path, detail: error.localizedDescription) }
    }

    /// Read without creating authority for display-only callers; missing is nil, while existing invalid state remains unavailable.
    public static func peekExisting(at url: URL) throws(Unavailable) -> SymmetricKey? {
        switch targetKind(at: url) {
        case .missing:
            return nil
        case .existing:
            return try readAndVerify(at: url)
        case .unavailable(let detail):
            throw Unavailable(path: url.path, detail: detail)
        }
    }

    private enum TargetKind {
        case missing
        case existing
        case unavailable(String)
    }

    private static func targetKind(at url: URL) -> TargetKind {
        var info = stat()
        if unsafe lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                return .unavailable("existing state must be a regular file, not a symlink or special file")
            }
            return .existing
        }
        if errno == ENOENT { return .missing }
        return .unavailable("existing state cannot be inspected: \(errorText(errno))")
    }

    private static func readAndVerify(at url: URL) throws(Unavailable) -> SymmetricKey {
        guard let descriptor = OwnedFD(raw: unsafe Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)) else {
            throw unavailable(url, operation: "read existing state", code: errno)
        }
        let fd = descriptor.raw

        var info = stat()
        guard unsafe fstat(fd, &info) == 0 else {
            throw unavailable(url, operation: "inspect existing state", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw Unavailable(path: url.path, detail: "existing state must be a regular file")
        }
        guard (info.st_mode & 0o7777) == 0o600 else {
            throw Unavailable(path: url.path, detail: "existing state must have mode 0600")
        }
        guard info.st_size == 32 else {
            throw Unavailable(
                path: url.path,
                detail: "existing state contains \(info.st_size) bytes; expected 32"
            )
        }
        return try readExactly(fd: fd, url: url)
    }

    private static func createAndVerify(_ secret: SymmetricKey, at url: URL, parent: URL) throws(Unavailable) -> SymmetricKey {
        var descriptor = OwnedFD(raw: unsafe Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        ))
        guard let fd = descriptor?.raw else {
            // A racing creator owns existing authority; validate it without overwriting.
            if errno == EEXIST {
                return try readAndVerify(at: url)
            }
            throw unavailable(url, operation: "create state", code: errno)
        }

        var createdInfo = stat()
        let ownsCreatedInode = unsafe fstat(fd, &createdInfo) == 0
        var complete = false
        defer {
            descriptor = nil
            if !complete, ownsCreatedInode {
                removeIfSameInode(at: url, device: createdInfo.st_dev, inode: createdInfo.st_ino)
            }
        }

        guard fchmod(fd, 0o600) == 0 else {
            throw unavailable(url, operation: "secure generated state", code: errno)
        }
        try writeAll(secret, fd: fd, url: url)
        guard fsync(fd) == 0 else {
            throw unavailable(url, operation: "sync generated state", code: errno)
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else {
            throw unavailable(url, operation: "rewind generated state", code: errno)
        }

        var verifiedInfo = stat()
        guard unsafe fstat(fd, &verifiedInfo) == 0,
              (verifiedInfo.st_mode & S_IFMT) == S_IFREG,
              (verifiedInfo.st_mode & 0o7777) == 0o600,
              verifiedInfo.st_size == 32 else {
            throw Unavailable(
                path: url.path,
                detail: "generated state failed regular-file, length, or mode verification"
            )
        }
        let persisted = try readExactly(fd: fd, url: url)
        guard persisted == secret else {
            throw Unavailable(path: url.path, detail: "generated state failed durable read-back verification")
        }

        // Persist the directory entry as well as the file contents before returning bytes that callers may publish or use for signatures.
        guard let directoryFD = OwnedFD(raw: unsafe Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)) else {
            throw unavailable(url, operation: "open secret directory for sync", code: errno)
        }
        guard fsync(directoryFD.raw) == 0 else {
            throw unavailable(url, operation: "sync secret directory", code: errno)
        }
        complete = true
        return persisted
    }

    private static func readExactly(fd: Int32, url: URL) throws(Unavailable) -> SymmetricKey {
        return try checked(at: url) {
            try SecretBytes<32>.withStorage { secret in
                let buffer = unsafe secret.buffer
                var offset = 0
                while offset < buffer.count {
                    let n = unsafe Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n < 0 { throw unavailable(url, operation: "read state", code: errno) }
                    guard n > 0 else {
                        throw Unavailable(path: url.path, detail: "state became truncated while reading; got \(offset) of \(buffer.count) bytes")
                    }
                    offset += n
                }
                return unsafe SymmetricKey(data: UnsafeRawBufferPointer(buffer))
            }
        }
    }

    private static func writeAll(_ data: SymmetricKey, fd: Int32, url: URL) throws(Unavailable) {
        var offset = 0
        try checked(at: url) {
            try unsafe data.withUnsafeBytes { rawBuffer in
                guard let base = unsafe rawBuffer.baseAddress else { return }
                while offset < rawBuffer.count {
                    let count = unsafe Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw unavailable(url, operation: "write generated state", code: errno)
                    }
                }
            }
        }
    }

    private static func removeIfSameInode(at url: URL, device: dev_t, inode: ino_t) {
        var current = stat()
        guard unsafe lstat(url.path, &current) == 0,
              current.st_dev == device,
              current.st_ino == inode else { return }
        _ = unlink(url.path)
    }

    private static func unavailable(_ url: URL, operation: String, code: Int32) -> Unavailable {
        Unavailable(path: url.path, detail: "\(operation) failed: \(errorText(code))")
    }

    private static func errorText(_ code: Int32) -> String {
        unsafe String(cString: strerror(code))
    }
}
