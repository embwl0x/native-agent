import Foundation
import Darwin
import CryptoKit
// Blueprint: | `VerifiedPath.swift` | VerifiedPath owns symlink-refusing descriptor-relative path walks, opens and file transfers |

package enum VerifiedPath {

    package enum Failure: Error {
        case symlinkComponent(String)
        case notFound
        case posix(Int32)

        package var message: String {
            switch self {
            case .symlinkComponent(let component):
                return "Path component '\(component)' is a symbolic link; the authorized path changed after it was checked."
            case .notFound:
                return "File not found"
            case .posix(let code):
                return String(cString: strerror(code))
            }
        }

        package var code: String {
            switch self {
            case .symlinkComponent: return "path_not_allowed"
            case .notFound: return "file_not_found"
            case .posix: return "read_failed"
            }
        }
    }

    /// Perform every mutation relative to the verified parent descriptor so path replacement cannot redirect it.
    package struct Parent {
        package let fd: Int32
        package let name: String

        package func release() {
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #endif
        }
    }

    #if canImport(Darwin)

    /// O_NOFOLLOW reports intermediate symlinks as ENOTDIR; ask the kernel so the refusal names the actual symlink fence.
    private static func classify(_ code: Int32, at fd: Int32, component: String) -> Failure {
        var metadata = stat()
        if fstatat(fd, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
           metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            return .symlinkComponent(component)
        }
        switch code {
        case ELOOP: return .symlinkComponent(component)
        case ENOENT, ENOTDIR: return .notFound
        default: return .posix(code)
        }
    }

    /// Restore only verified system aliases /var, /tmp and /etc to /private before the strict component walk.
    private static func walkPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for prefix in ["/var", "/tmp", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            var linked = stat()
            var real = stat()
            guard lstat(prefix, &linked) == 0,
                  linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                  lstat("/private" + prefix, &real) == 0,
                  real.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
            return "/private" + path
        }
        return path
    }

    /// Create missing parents relative to verified descriptors, then reopen O_NOFOLLOW so a racing swap cannot redirect the walk.
    package static func openParent(of url: URL, createIntermediates: Bool = false) throws -> Parent {
        let components = walkPath(url).split(separator: "/").map(String.init)
        guard let final = components.last else { throw Failure.notFound }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.posix(errno) }
        for component in components.dropLast() {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, createIntermediates, errno == ENOENT {
                do { try Task.checkCancellation() }
                catch { _ = Darwin.close(fd); throw error }
                // After EEXIST, O_NOFOLLOW must judge the entry that won the creation race.
                if mkdirat(fd, component, 0o755) != 0, errno != EEXIST {
                    let failure = Failure.posix(errno)
                    _ = Darwin.close(fd)
                    throw failure
                }
                next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let failure = classify(errno, at: fd, component: component)
                _ = Darwin.close(fd)
                throw failure
            }
            _ = Darwin.close(fd)
            fd = next
        }
        return Parent(fd: fd, name: final)
    }

    /// Open relative to the verified parent without following the final component.
    package static func openFinal(_ parent: Parent, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let fd = openat(parent.fd, parent.name, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw classify(errno, at: parent.fd, component: parent.name) }
        return fd
    }

    package static func open(_ url: URL, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        if url.standardizedFileURL.path == "/" {
            let fd = Darwin.open("/", flags | O_NOFOLLOW | O_CLOEXEC, mode)
            guard fd >= 0 else { throw Failure.posix(errno) }
            return fd
        }
        let parent = try openParent(of: url)
        defer { parent.release() }
        return try openFinal(parent, flags: flags, mode: mode)
    }

    /// External-process callers need current path proof because they cannot pass descriptor-relative authority.
    package static func confirmNoSymlink(_ url: URL) throws {
        let fd = try open(url, flags: O_RDONLY | O_NONBLOCK)
        _ = Darwin.close(fd)
    }

    package static func transfer(from source: URL, to target: URL, copy: Bool, overwrite: Bool) throws {
        try Task.checkCancellation()
        let from = try openParent(of: source)
        defer { from.release() }
        var metadata = stat()
        guard fstatat(from.fd, from.name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.posix(errno) }
        guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(metadata.st_mode & mode_t(S_IFMT)),
              !copy || metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
                copy ? "Copy requires a regular file. Folder copies are not supported."
                    : "Source must be a regular file, folder or symbolic link; special files are not transferred."])
        }
        let to = try openParent(of: target, createIntermediates: true)
        defer { to.release() }
        if !overwrite {
            if fstatat(to.fd, to.name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.posix(EEXIST) }
            guard errno == ENOENT else { throw Failure.posix(errno) }
        }
        let flags = overwrite ? UInt32(0) : UInt32(RENAME_EXCL)
        if copy {
            let sourceFD = try openFinal(from, flags: O_RDONLY | O_NONBLOCK)
            defer { _ = Darwin.close(sourceFD) }
            guard fstat(sourceFD, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw CocoaError(.fileReadUnsupportedScheme,
                    userInfo: [NSLocalizedDescriptionKey: "Copy requires a regular file. Folder copies are not supported."])
            }
            let temporary = ".\(UUID().uuidString).copy"
            let targetFD = openat(to.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard targetFD >= 0 else { throw Failure.posix(errno) }
            defer { _ = Darwin.close(targetFD); _ = unlinkat(to.fd, temporary, 0) }
            guard fcopyfile(sourceFD, targetFD, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw Failure.posix(errno) }
            try Task.checkCancellation()
            guard renameatx_np(to.fd, temporary, to.fd, to.name, flags) == 0 else { throw Failure.posix(errno) }
        } else {
            try Task.checkCancellation()
            guard renameatx_np(from.fd, from.name, to.fd, to.name, flags) == 0 else { throw Failure.posix(errno) }
        }
    }

    #endif
}
