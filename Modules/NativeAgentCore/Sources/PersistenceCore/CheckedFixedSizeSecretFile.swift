import Darwin
import Foundation

/// Mechanical storage for a fixed-size local secret.
///
/// This type deliberately owns no authority domain and no secret lifecycle.
/// Callers retain those decisions. It only enforces the persistence invariant
/// shared by local authority files: missing state may bootstrap once, while
/// existing invalid state is unavailable and is never repaired or replaced.
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

    /// Load an exact regular 0600 file, or durably create it when and only when
    /// the target is missing. Creation and reads serialize on a sidecar flock.
    /// The newly-created bytes are fsync'd, permission-checked, and read back
    /// from the same descriptor before they may leave this function.
    public static func loadOrCreate(
        at url: URL,
        byteCount: Int,
        generate: () throws -> Data
    ) throws -> Data {
        guard byteCount > 0 else {
            throw Unavailable(path: url.path, detail: "expected byte count must be positive")
        }

        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw Unavailable(
                path: url.path,
                detail: "cannot create secret directory: \(error.localizedDescription)"
            )
        }

        let lockPath = url.path + ".lock"
        let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else {
            throw unavailable(url, operation: "open lock", code: errno)
        }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw unavailable(url, operation: "lock", code: errno)
        }
        defer { _ = flock(lockFD, LOCK_UN) }

        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0,
              (lockStat.st_mode & S_IFMT) == S_IFREG else {
            throw Unavailable(path: url.path, detail: "lock state is not a regular file")
        }
        guard fchmod(lockFD, 0o600) == 0 else {
            throw unavailable(url, operation: "secure lock permissions", code: errno)
        }

        switch targetKind(at: url) {
        case .missing:
            let generated: Data
            do {
                generated = try generate()
            } catch {
                throw Unavailable(
                    path: url.path,
                    detail: "secret generation failed: \(error.localizedDescription)"
                )
            }
            guard generated.count == byteCount else {
                throw Unavailable(
                    path: url.path,
                    detail: "generator returned \(generated.count) bytes; expected \(byteCount)"
                )
            }
            return try createAndVerify(generated, at: url, parent: parent)

        case .existing:
            return try readAndVerify(at: url, byteCount: byteCount)

        case .unavailable(let detail):
            throw Unavailable(path: url.path, detail: detail)
        }
    }

    /// Deliberately replace an existing valid secret with newly generated
    /// bytes. The old and new files are atomically swapped under the same
    /// sidecar lock used by `loadOrCreate`; the old bytes remain available for
    /// rollback until the new inode, directory entry, mode, length, and
    /// read-back have all been verified. Existing invalid state is never
    /// repaired by rotation.
    public static func replace(
        at url: URL,
        byteCount: Int,
        generate: () throws -> Data
    ) throws -> Data {
        guard byteCount > 0 else {
            throw Unavailable(path: url.path, detail: "expected byte count must be positive")
        }

        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw Unavailable(
                path: url.path,
                detail: "cannot create secret directory: \(error.localizedDescription)"
            )
        }

        let lockPath = url.path + ".lock"
        let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else {
            throw unavailable(url, operation: "open lock", code: errno)
        }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw unavailable(url, operation: "lock", code: errno)
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        guard fchmod(lockFD, 0o600) == 0 else {
            throw unavailable(url, operation: "secure lock permissions", code: errno)
        }

        // Validate before generating so a damaged authority file is preserved
        // byte-for-byte instead of being silently repaired by "Regenerate".
        _ = try readAndVerify(at: url, byteCount: byteCount)
        var originalInfo = stat()
        guard lstat(url.path, &originalInfo) == 0,
              (originalInfo.st_mode & S_IFMT) == S_IFREG else {
            throw Unavailable(path: url.path, detail: "existing state changed during rotation")
        }

        let generated: Data
        do {
            generated = try generate()
        } catch {
            throw Unavailable(
                path: url.path,
                detail: "secret generation failed: \(error.localizedDescription)"
            )
        }
        guard generated.count == byteCount else {
            throw Unavailable(
                path: url.path,
                detail: "generator returned \(generated.count) bytes; expected \(byteCount)"
            )
        }

        let temporaryURL = parent.appendingPathComponent(".\(url.lastPathComponent).rotate.\(UUID().uuidString)")
        let temporaryFD = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard temporaryFD >= 0 else {
            throw unavailable(url, operation: "create replacement state", code: errno)
        }

        var swapped = false
        var complete = false
        defer {
            Darwin.close(temporaryFD)
            var mayRemoveTemporary = !swapped
            if swapped, !complete {
                mayRemoveTemporary = renameatx_np(
                    AT_FDCWD, temporaryURL.path,
                    AT_FDCWD, url.path,
                    UInt32(RENAME_SWAP)
                ) == 0
            }
            if mayRemoveTemporary,
               (!complete || fileManager.fileExists(atPath: temporaryURL.path)) {
                _ = unlink(temporaryURL.path)
            }
        }

        do {
            guard fchmod(temporaryFD, 0o600) == 0 else {
                throw unavailable(url, operation: "secure replacement state", code: errno)
            }
            try writeAll(generated, fd: temporaryFD, url: temporaryURL)
            guard fsync(temporaryFD) == 0,
                  lseek(temporaryFD, 0, SEEK_SET) == 0 else {
                throw unavailable(url, operation: "sync replacement state", code: errno)
            }
            let staged = try readExactly(fd: temporaryFD, byteCount: byteCount, url: temporaryURL)
            guard staged == generated else {
                throw Unavailable(path: url.path, detail: "replacement state failed read-back verification")
            }

            var currentInfo = stat()
            guard lstat(url.path, &currentInfo) == 0,
                  currentInfo.st_dev == originalInfo.st_dev,
                  currentInfo.st_ino == originalInfo.st_ino else {
                throw Unavailable(path: url.path, detail: "existing state changed during rotation")
            }
            guard renameatx_np(
                AT_FDCWD, temporaryURL.path,
                AT_FDCWD, url.path,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw unavailable(url, operation: "atomically swap replacement state", code: errno)
            }
            swapped = true

            let persisted = try readAndVerify(at: url, byteCount: byteCount)
            guard persisted == generated else {
                throw Unavailable(path: url.path, detail: "replacement state failed canonical read-back")
            }
            let directoryFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0 else {
                throw unavailable(url, operation: "open secret directory for sync", code: errno)
            }
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else {
                throw unavailable(url, operation: "sync replacement directory entry", code: errno)
            }
            guard unlink(temporaryURL.path) == 0 else {
                throw unavailable(url, operation: "remove superseded secret", code: errno)
            }
            // The canonical replacement was already directory-fsync'd while
            // the old inode still existed for rollback. Once unlink succeeds,
            // there is no honest rollback path left; a second directory fsync
            // is best-effort cleanup durability and must not report rotation as
            // failed while leaving the verified new canonical bytes active.
            _ = fsync(directoryFD)
            complete = true
            return persisted
        } catch let error as Unavailable {
            throw error
        } catch {
            throw Unavailable(path: url.path, detail: error.localizedDescription)
        }
    }

    private enum TargetKind {
        case missing
        case existing
        case unavailable(String)
    }

    private static func targetKind(at url: URL) -> TargetKind {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                return .unavailable("existing state must be a regular file, not a symlink or special file")
            }
            return .existing
        }
        if errno == ENOENT { return .missing }
        return .unavailable("existing state cannot be inspected: \(errorText(errno))")
    }

    private static func readAndVerify(at url: URL, byteCount: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw unavailable(url, operation: "read existing state", code: errno)
        }
        defer { Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw unavailable(url, operation: "inspect existing state", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw Unavailable(path: url.path, detail: "existing state must be a regular file")
        }
        guard (info.st_mode & 0o7777) == 0o600 else {
            throw Unavailable(path: url.path, detail: "existing state must have mode 0600")
        }
        guard info.st_size == off_t(byteCount) else {
            throw Unavailable(
                path: url.path,
                detail: "existing state contains \(info.st_size) bytes; expected \(byteCount)"
            )
        }
        return try readExactly(fd: fd, byteCount: byteCount, url: url)
    }

    private static func createAndVerify(_ secret: Data, at url: URL, parent: URL) throws -> Data {
        let fd = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else {
            // A non-cooperating creator may have won after our missing-state
            // check. Never overwrite it; validate it as existing authority.
            if errno == EEXIST {
                return try readAndVerify(at: url, byteCount: secret.count)
            }
            throw unavailable(url, operation: "create state", code: errno)
        }

        var createdInfo = stat()
        let ownsCreatedInode = fstat(fd, &createdInfo) == 0
        var complete = false
        defer {
            Darwin.close(fd)
            if !complete, ownsCreatedInode {
                removeIfSameInode(at: url, device: createdInfo.st_dev, inode: createdInfo.st_ino)
            }
        }

        do {
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
            guard fstat(fd, &verifiedInfo) == 0,
                  (verifiedInfo.st_mode & S_IFMT) == S_IFREG,
                  (verifiedInfo.st_mode & 0o7777) == 0o600,
                  verifiedInfo.st_size == off_t(secret.count) else {
                throw Unavailable(
                    path: url.path,
                    detail: "generated state failed regular-file, length, or mode verification"
                )
            }
            let persisted = try readExactly(fd: fd, byteCount: secret.count, url: url)
            guard persisted == secret else {
                throw Unavailable(path: url.path, detail: "generated state failed durable read-back verification")
            }

            // Persist the directory entry as well as the file contents before
            // returning bytes that callers may publish or use for signatures.
            let directoryFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0 else {
                throw unavailable(url, operation: "open secret directory for sync", code: errno)
            }
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else {
                throw unavailable(url, operation: "sync secret directory", code: errno)
            }
            complete = true
            return persisted
        } catch let error as Unavailable {
            throw error
        } catch {
            throw Unavailable(path: url.path, detail: error.localizedDescription)
        }
    }

    private static func readExactly(fd: Int32, byteCount: Int, url: URL) throws -> Data {
        var output = Data(count: byteCount)
        var offset = 0
        try output.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < byteCount {
                let count = Darwin.read(fd, base.advanced(by: offset), byteCount - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw unavailable(url, operation: "read state", code: errno)
                }
            }
        }
        guard offset == byteCount else {
            throw Unavailable(
                path: url.path,
                detail: "state became truncated while reading; got \(offset) of \(byteCount) bytes"
            )
        }
        return output
    }

    private static func writeAll(_ data: Data, fd: Int32, url: URL) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
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

    private static func removeIfSameInode(at url: URL, device: dev_t, inode: ino_t) {
        var current = stat()
        guard lstat(url.path, &current) == 0,
              current.st_dev == device,
              current.st_ino == inode else { return }
        _ = unlink(url.path)
    }

    private static func unavailable(_ url: URL, operation: String, code: Int32) -> Unavailable {
        Unavailable(path: url.path, detail: "\(operation) failed: \(errorText(code))")
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
