import Foundation
// Blueprint: | `NativeAgentWorkspaceRoot.swift` | Canonical workspace root, byte-preserving file spelling, target/entry canonicalization and byte-exact component-relative paths; callers select bases and retain admission authority |

/// Canonical user-work root for every NativeAgent surface.
///
/// A source-backed development install keeps the historical `<repo>/workspace`
/// location. A public/app-only install has no source checkout, so its workspace
/// lives inside the canonical application data root:
/// `~/Library/Application Support/NativeAgent/workspace`.
///
/// For data-root work files: local backup/export and phone file-content sync
/// exclude workspace/; off-disk backup includes it; PrivacyMap lists it.
/// File contents are task-defined, owned by the tool that creates them.
/// This owns only path resolution and directory preparation. TrustCenter and
/// each tool's execution boundary retain permission and effect authority.
public enum NativeAgentWorkspaceRoot {
    /// Compare caller-selected lexical or resolved paths by filesystem bytes.
    /// Equality has an empty tail; outside paths have no tail.
    public static func relativePath(_ path: String, under root: String) -> String? {
        if path.utf8.elementsEqual(root.utf8) { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.utf8.starts(with: prefix.utf8) else { return nil }
        return String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }

    public static func resolve(
        dataRoot: URL = defaultDataRoot(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["NATIVE_AGENT_WORKSPACE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
                .standardizedFileURL
        }

        if let repoRoot = resolveSandboxRepoRoot(dataRoot: dataRoot, fileManager: fileManager) {
            return repoRoot
                .appendingPathComponent("workspace", isDirectory: true)
                .standardizedFileURL
        }

        return dataRoot
            .appendingPathComponent("workspace", isDirectory: true)
            .standardizedFileURL
    }

    /// The path file mutations actually use, shared with containment. Relative
    /// names (including the workspace/ alias) start in the canonical workspace.
    /// Preserve whitespace; it is part of the file name.
    public static func resolveFileMutationPath(_ raw: String, dataRoot: URL) -> URL {
        let workspace = resolve(dataRoot: dataRoot)
        return canonicalFileURL(fileCandidate(raw, relativeTo: workspace, workspaceRoot: workspace))
    }

    /// The entry a move or trash acts on: its folder's aliases resolved, the named
    /// item kept, so a symlink is moved or trashed itself and never its target.
    public static func resolveFileEntryPath(_ raw: String, dataRoot: URL) -> URL {
        let workspace = resolve(dataRoot: dataRoot)
        return canonicalFileURL(fileCandidate(raw, relativeTo: workspace, workspaceRoot: workspace), followFinalLink: false)
    }

    /// Resolve folder aliases, optionally keeping the final entry itself.
    /// macOS firmlink spellings also canonicalize when the leaf does not exist.
    public static func canonicalFileURL(_ candidate: URL, followFinalLink: Bool = true) -> URL {
        let entry = candidate.standardizedFileURL
        let resolved = followFinalLink || entry.path == "/" ? entry.resolvingSymlinksInPath()
            : entry.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(entry.lastPathComponent)
        for prefix in ["/etc", "/tmp", "/var"] {
            if (followFinalLink && resolved.path == prefix) || resolved.path.hasPrefix(prefix + "/") {
                return URL(fileURLWithPath: "/private" + resolved.path)
            }
        }
        return resolved
    }

    public static func normalizeWorkspaceAlias(_ path: String, workspaceRoot: URL) -> String {
        if path == "workspace" || path == "workspace/" { return workspaceRoot.path }
        return path.hasPrefix("workspace/")
            ? workspaceRoot.appendingPathComponent(String(path.dropFirst("workspace/".count))).standardizedFileURL.path
            : path
    }

    /// Spelling only; callers own containment, source selection and final links.
    public static func fileCandidate(_ raw: String, relativeTo base: URL, workspaceRoot: URL? = nil) -> URL {
        var path = fileSpelling(raw)
        if let workspaceRoot { path = normalizeWorkspaceAlias(path, workspaceRoot: workspaceRoot) }
        if path.lowercased() == "/documents" || path.lowercased().hasPrefix("/documents/") {
            path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
                .appendingPathComponent(String(path.dropFirst("/documents".count))).path
        }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }

    public static func fileSpelling(_ raw: String) -> String {
        let path: String
        if let address = URL(string: raw), address.isFileURL {
            path = address.path
        } else if !raw.hasPrefix("/"), let decoded = raw.removingPercentEncoding, decoded.hasPrefix("/") {
            path = decoded
        } else {
            path = raw
        }
        return (path as NSString).expandingTildeInPath
    }

    @discardableResult
    public static func prepare(
        dataRoot: URL = defaultDataRoot(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = resolve(
            dataRoot: dataRoot,
            environment: environment,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory does not tighten an already-existing directory.
        // Reassert the public workspace boundary on every launch/first use.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        return root
    }
}
