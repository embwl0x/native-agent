import Foundation

/// Canonical user-work root for every NativeAgent surface.
///
/// A source-backed development install keeps the historical `<repo>/workspace`
/// location. A public/app-only install has no source checkout, so its workspace
/// lives inside the canonical application data root:
/// `~/Library/Application Support/NativeAgent/workspace`.
///
/// This owns only path resolution and directory preparation. TrustCenter and
/// each tool's execution boundary retain permission and effect authority.
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
