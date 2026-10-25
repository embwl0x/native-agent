import Foundation
// Blueprint: | `NativeAgentWorkspaceRoot.swift` | Canonical workspace root; `resolveFileMutationPath` is the shared byte-preserving path resolver for file mutation execution and containment, including the workspace base for relative names |

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
/// Caller-defined files, excluded from automatic backup/export/phone sync;
/// PrivacyMap resolves this same workspace root, including checkout locations.
public enum NativeAgentWorkspaceRoot {
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
        let path: String
        if let address = URL(string: raw), address.isFileURL {
            path = address.path
        } else if !raw.hasPrefix("/"), let decoded = raw.removingPercentEncoding, decoded.hasPrefix("/") {
            path = decoded
        } else {
            path = raw
        }
        let expanded = (path as NSString).expandingTildeInPath
        let candidate: URL
        if expanded == "workspace" || expanded == "workspace/" {
            candidate = workspace
        } else if expanded.hasPrefix("workspace/") {
            candidate = workspace.appendingPathComponent(String(expanded.dropFirst("workspace/".count)))
        } else if expanded.lowercased() == "/documents" || expanded.lowercased().hasPrefix("/documents/") {
            // Keep the file tools' existing Full Mac Documents shorthand.
            let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            candidate = documents.appendingPathComponent(String(expanded.dropFirst("/documents".count)))
        } else if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else {
            candidate = workspace.appendingPathComponent(expanded)
        }
        return candidate.standardizedFileURL.resolvingSymlinksInPath()
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
