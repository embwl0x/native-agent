import Foundation
import ImageIO
import NativeAgentCore
import PersistenceCore
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

// MARK: - TOCTOU fence for the ported file connector actions
//
// `FileSystemActions.resolvePath` canonicalises a path and the sandbox +
// sensitive-subtree checks judge that canonical STRING. Every use then reopened
// the same string by pathname — regular reads (no `O_NOFOLLOW`), image decoding
// (validated one handle, reopened the path to decode), appends (followed the
// final symlink and unverified parents), directory listing and grep (authorized,
// then opened/spawned against the mutable path). A same-user process could swap
// a final or a parent symlink in that window, so the check and the use named
// different files.
//
// `VerifiedPath` closes the window: it re-opens the ALREADY-CHECKED path one
// component at a time from `/`, each `openat` carrying `O_DIRECTORY|O_NOFOLLOW`,
// and hands back a descriptor for the verified parent directory plus the final
// component name. Because `resolvePath` resolved symlinks before the check, a
// component that is a symlink NOW is a component that changed after the check —
// `openat` returns `ELOOP` and the walk fails CLOSED. Reads, image decoding,
// appends, atomic overwrites (temp + `renameat` inside the verified parent) and
// listing then all run through that descriptor, never through the pathname
// again; grep, which must hand a path to an external engine, spawns only after
// the walk has confirmed no component is a symlink.

enum VerifiedPath {

    enum Failure: Error {
        /// A component of the checked path is a symlink now. Fail closed.
        case symlinkComponent(String)
        case notFound
        case posix(Int32)

        var message: String {
            switch self {
            case .symlinkComponent(let component):
                return "Path component '\(component)' is a symbolic link; the authorized path changed after it was checked."
            case .notFound:
                return "File not found"
            case .posix(let code):
                return String(cString: strerror(code))
            }
        }

        var code: String {
            switch self {
            case .symlinkComponent: return "path_not_allowed"
            case .notFound: return "file_not_found"
            case .posix: return "read_failed"
            }
        }
    }

    /// A descriptor for the verified parent directory plus the final path
    /// component. Every mutation and open is performed relative to `fd`.
    struct Parent {
        let fd: Int32
        let name: String

        func release() {
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #endif
        }
    }

    #if canImport(Darwin)

    /// `O_NOFOLLOW` reports a symlink component as `ELOOP` or, for an
    /// intermediate one, `ENOTDIR`. Ask the kernel which it was so the fence
    /// says "this component became a symlink" rather than "not found".
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

    /// The path to walk component-by-component.
    ///
    /// `resolvePath` canonicalises with Foundation's `resolvingSymlinksInPath`,
    /// which on macOS STRIPS a leading `/private` instead of adding it — so a
    /// fully "resolved" temp path is `/var/folders/…` whose first component is
    /// itself a symlink to `private/var`. That is Foundation's normalisation,
    /// not an attacker's swap, so undo exactly it (and nothing else) before the
    /// `O_NOFOLLOW` walk; every component below the prefix is still walked
    /// strictly.
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

    /// Walk `url`'s parent chain from `/`, refusing to follow any symlink.
    ///
    /// `createIntermediates` makes a missing component with `mkdirat` INSIDE
    /// the walk, on the descriptor of the parent just verified. The write side
    /// used to call a path-based `FileManager.createDirectory` BEFORE the walk
    /// — the one operation that resolved the whole pathname again, following
    /// symlinks, and so could create directories outside the sandbox root when
    /// a parent was swapped after the check. Created here, each new component
    /// is reopened `O_NOFOLLOW` like every other one, so a racing swap fails
    /// the walk instead of redirecting it.
    static func openParent(of url: URL, createIntermediates: Bool = false) throws -> Parent {
        let components = walkPath(url).split(separator: "/").map(String.init)
        guard let final = components.last else { throw Failure.notFound }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.posix(errno) }
        for component in components.dropLast() {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, createIntermediates, errno == ENOENT {
                // EEXIST: someone else made it in the gap — reopen and let the
                // O_NOFOLLOW reopen judge whatever is there now.
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

    /// Open the final component relative to the verified parent, never
    /// following it.
    static func openFinal(_ parent: Parent, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let fd = openat(parent.fd, parent.name, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw classify(errno, at: parent.fd, component: parent.name) }
        return fd
    }

    /// Walk + open in one step, for callers that do not need the parent after.
    static func open(_ url: URL, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let parent = try openParent(of: url)
        defer { parent.release() }
        return try openFinal(parent, flags: flags, mode: mode)
    }

    /// Prove that no component of `url` is a symlink right now. Used by the one
    /// consumer that must pass a pathname to an external process.
    static func confirmNoSymlink(_ url: URL) throws {
        let fd = try open(url, flags: O_RDONLY | O_NONBLOCK)
        _ = Darwin.close(fd)
    }

    #endif
}

// MARK: - Image pixels decoded from the verified descriptor

/// `LocalToolImage.readAuthorizedFile` reopens the URL to decode it, which is
/// exactly the swap window the walk above closes. This decodes the bytes the
/// verified descriptor already produced and returns the SAME receipt shape
/// (same keys, same note, same failure strings).
enum VerifiedImageRead {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp",
    ]

    static func isImagePath(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func failure(_ reason: String) -> JSONValue {
        .object(["status": .string("failed"), "error": .string(reason)])
    }

    static func deliver(data: Data, name: String) -> JSONValue {
        guard LocalToolImage.sink != nil else {
            return failure("No image slot for this call: it is text-only, or this round already reads 8 images. Read it in the next call.")
        }
        guard !data.isEmpty, data.count <= LocalToolImage.maximumBytes else {
            return failure("Image must be a nonempty regular file of at most 8 MiB.")
        }
        guard let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000,
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else {
            return failure("Image is unreadable, unsupported, or exceeds the 40-megapixel limit.")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                encoded, UTType.png.identifier as CFString, 1, nil) else {
            return failure("Could not encode image pixels.")
        }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= LocalToolImage.maximumBytes else {
            return failure("Encoded image exceeds the 8 MiB delivery limit.")
        }
        let delivered = LocalToolImage.deliverPNG(
            encoded as Data, name: name, width: pixels.width, height: pixels.height)
        // Keep the reader's receipt: it reports the SOURCE dimensions and says
        // what the bounded thumbnail is and is not.
        guard case .object(var fields) = delivered,
              case .string("ok")? = fields["status"] else { return delivered }
        fields["source_width"] = .int(Int64(width))
        fields["source_height"] = .int(Int64(height))
        fields["note"] = .string("Actual image follows this tool result. First frame, oriented and bounded to 2048 pixels; not OCR or a text description.")
        return .object(fields)
    }
}
