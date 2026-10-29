import Foundation
import Darwin
import PersistenceCore
// Blueprint: | `WorkshopArtifactWriter.swift` | `WorkshopArtifactWriter` descriptor-anchored handle-scoped artifact filesystem, safe components and bounded UTF-8 reads |

/// Descriptor-anchored UTF-8 artifacts under data/workshop/<handle>/; validated
/// components and O_NOFOLLOW directory walks keep writes inside the handle root.
/// Workshop backup/export includes artifacts; phone sync carries no content.
public struct WorkshopArtifactWriter: Sendable {
    /// The app data root (e.g. `.../data`); artifacts live under
    /// `<dataRoot>/workshop/<handle>/`.
    let dataRoot: URL
    let handle: String

    public init(dataRoot: URL, handle: String) {
        self.dataRoot = dataRoot
        self.handle = handle
    }

    /// The absolute root for this pursuit's artifacts. The handle is validated
    /// as a safe single component so it can never itself traverse.
    public func rootURL() throws -> URL {
        let safeHandle = try Self.validateSafeComponent(handle)
        return dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent(safeHandle, isDirectory: true)
    }

    public struct Written: Equatable { public let relativePath: String; public let url: URL }
    public struct Read: Equatable {
        public let relativePath: String
        public let content: String
        public let bytes: Int
        public let truncated: Bool
    }

    @discardableResult
    public func write(relativePath: String, content: String) throws -> Written {
        let components = try Self.validatedPathComponents(relativePath)
        let root = try rootURL()
        let target = Written(
            relativePath: components.joined(separator: "/"),
            url: components.reduce(root) { $0.appendingPathComponent($1) }
        )

        // Anchor the whole operation at an O_NOFOLLOW descriptor for dataRoot,
        // then walk/create every directory with openat/mkdirat. The final file
        // is written to an O_EXCL temporary sibling and renameat'd within the
        // already-open parent. No path component is resolved a second time, so
        // a parent symlink cannot be swapped in between validation and write.
        let dataFD = Darwin.open(
            dataRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard dataFD >= 0 else { throw Self.posixError("open data root") }
        defer { Darwin.close(dataFD) }

        var directoryFD = try Self.openDirectoryComponent("workshop", parentFD: dataFD, create: true)
        defer { Darwin.close(directoryFD) }
        let safeHandle = try Self.validateSafeComponent(handle)
        let handleFD = try Self.openDirectoryComponent(safeHandle, parentFD: directoryFD, create: true)
        Darwin.close(directoryFD)
        directoryFD = handleFD

        for component in components.dropLast() {
            let next = try Self.openDirectoryComponent(component, parentFD: directoryFD, create: true)
            Darwin.close(directoryFD)
            directoryFD = next
        }

        try SwiftNativePersistenceCore.atomicWrite(Data(content.utf8), to: target.url, parentFD: directoryFD)
        return target
    }

    /// Check bounded byte access without interpreting a partial UTF-8 scalar.
    public func isReadable(relativePath: String) -> Bool {
        (try? readBytes(relativePath: relativePath, maximumBytes: 1)) != nil
    }

    public func read(relativePath: String, maximumBytes: Int = 65_536) throws -> Read {
        let result = try readBytes(relativePath: relativePath, maximumBytes: maximumBytes)
        guard let content = String(data: result.data, encoding: .utf8) else {
            throw WorkshopMembraneError.badArtifactArgs("artifact is not UTF-8 text")
        }
        return Read(relativePath: result.relativePath, content: content, bytes: result.data.count, truncated: result.truncated)
    }

    private func readBytes(relativePath: String, maximumBytes: Int) throws -> (relativePath: String, data: Data, truncated: Bool) {
        let components = try Self.validatedPathComponents(relativePath)
        let dataFD = Darwin.open(dataRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dataFD >= 0 else { throw Self.posixError("open data root") }
        defer { Darwin.close(dataFD) }
        var directoryFD = try Self.openDirectoryComponent("workshop", parentFD: dataFD, create: false)
        defer { Darwin.close(directoryFD) }
        let handleFD = try Self.openDirectoryComponent(try Self.validateSafeComponent(handle), parentFD: directoryFD, create: false)
        Darwin.close(directoryFD)
        directoryFD = handleFD
        for component in components.dropLast() {
            let next = try Self.openDirectoryComponent(component, parentFD: directoryFD, create: false)
            Darwin.close(directoryFD)
            directoryFD = next
        }
        let leaf = components[components.count - 1]
        let fileFD = leaf.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fileFD >= 0 else { throw Self.posixError("open artifact") }
        defer { Darwin.close(fileFD) }
        var statValue = stat()
        guard Darwin.fstat(fileFD, &statValue) == 0, (statValue.st_mode & S_IFMT) == S_IFREG else {
            throw WorkshopMembraneError.badArtifactArgs("artifact is not a regular file")
        }
        let limit = max(1, maximumBytes)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(8192, limit + 1))
        while data.count <= limit {
            let requested = min(buffer.count, limit + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fileFD, raw.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError("read artifact")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let truncated = data.count > limit
        if truncated {
            data = data.prefix(limit)
            // Remove only a scalar cut by the byte limit; invalid text elsewhere
            // still fails the UTF-8 decode at the artifact boundary.
            var start = data.count - 1
            while start > 0, data[start] & 0xC0 == 0x80 { start -= 1 }
            let lead = data[start]
            let width = lead < 0x80 ? 1
                : (0xC2...0xDF).contains(lead) ? 2
                : (0xE0...0xEF).contains(lead) ? 3
                : (0xF0...0xF4).contains(lead) ? 4 : 0
            if width > data.count - start { data = data.prefix(start) }
        }
        return (relativePath: components.joined(separator: "/"), data: data, truncated: truncated)
    }

    private static func validatedPathComponents(_ rawPath: String) throws -> [String] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkshopMembraneError.badArtifactArgs("'path' must be non-empty")
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw WorkshopMembraneError.unsafeComponent(rawPath)
        }
        if trimmed.hasPrefix("/") || trimmed.contains("\\") {
            throw WorkshopMembraneError.pathEscapesRoot(rawPath)
        }
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        for component in components where component.isEmpty || component == "." || component == ".." {
            throw WorkshopMembraneError.unsafeComponent(rawPath)
        }
        return components
    }

    /// Descriptor-anchored directory walk shared with the reservation-claim
    /// ledger. Keeping both Workshop writers on `openat` + `O_NOFOLLOW` avoids
    /// reintroducing a path-based symlink parent between the two boundaries.
    static func openDirectoryComponent(
        _ component: String,
        parentFD: Int32,
        create: Bool
    ) throws -> Int32 {
        func openDirectory() -> Int32 {
            component.withCString {
                Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        var fd = openDirectory()
        if fd < 0, create, errno == ENOENT {
            let made = component.withCString { Darwin.mkdirat(parentFD, $0, 0o700) }
            if made != 0, errno != EEXIST {
                throw posixError("mkdir artifact component")
            }
            fd = openDirectory()
        }
        guard fd >= 0 else { throw posixError("open artifact component") }
        return fd
    }

    private static func posixError(_ operation: String) -> Error {
        let code = errno
        return NSError(
            domain: "WorkshopArtifactWriter",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
        )
    }

    /// The membrane's single-component path-safety guard.
    public static func validateSafeComponent(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw WorkshopMembraneError.unsafeComponent(raw) }
        if id == "." || id == ".." { throw WorkshopMembraneError.unsafeComponent(raw) }
        if id.contains("/") || id.contains("\\") || id.contains("\0") {
            throw WorkshopMembraneError.unsafeComponent(raw)
        }
        if id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw WorkshopMembraneError.unsafeComponent(raw)
        }
        return id
    }
}
