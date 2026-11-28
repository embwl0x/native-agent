import Foundation
import DeskCore
import NativeAgentCore
import PersistenceCore
import MacNerves
import Darwin
import NativeAgentShared
import CryptoKit
// Blueprint: | `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` |

/// Helper discovery and execution grant no authority; a subprocess result alone cannot verify work.
public enum AgentBridgeRuntime {
    /// Unreadable helpers remain absent; the caller names `expectedHelperPath` in its refusal.
    public static func helperURL(
        named name: String,
        dataRoot: URL,
        bundleResourceRoot: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        let path = expectedHelperPath(
            named: name, dataRoot: dataRoot, bundleResourceRoot: bundleResourceRoot)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path.path),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return nil
        }
        return path
    }

    /// Checkout installs use local scripts so edits apply without rebuilding; packaged installs use bundled resources.
    public static func expectedHelperPath(
        named name: String,
        dataRoot: URL,
        bundleResourceRoot: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
    ) -> URL {
        if let checkout = resolveSandboxRepoRoot(dataRoot: dataRoot) {
            return checkout.appendingPathComponent("script/\(name)").standardizedFileURL
        }
        return bundledHelper(named: name, resourceRoot: bundleResourceRoot).standardizedFileURL
    }

    /// An absent or incomplete saved identity cannot name a send.
    public static func configuredNames(dataRoot: URL) throws -> (agent: String, user: String) {
        do { return try PersonaCompiler.configuredNames(dataRoot: dataRoot) }
        catch {
            throw ToolFailureError(error.localizedDescription, effects: .none,
                owner: dataRoot.appendingPathComponent("memory/profile.json").path,
                tap: "Repair memory/profile.json before starting the helper.", code: "persona_profile_unavailable")
        }
    }

    public static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["NATIVE_AGENT_BRIDGE_NODE_BIN"] {
            return firstExecutable([URL(fileURLWithPath: override)], fileManager: fileManager)
        }

        let directories = (processEnvironment(base: environment, homeDirectory: homeDirectory)["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        var candidates = unique(directories).map { $0.appendingPathComponent("node") }
        let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versionDirectories = ((try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        candidates.append(contentsOf: versionDirectories.map { $0.appendingPathComponent("bin/node") })
        return firstExecutable(candidates, fileManager: fileManager)
    }

    public static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var result = base
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        let additions = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".claude/bin").path,
            homeDirectory.appendingPathComponent(".codex/bin").path,
            homeDirectory.appendingPathComponent(".volta/bin").path,
            homeDirectory.appendingPathComponent(".local/share/mise/shims").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        result["PATH"] = uniqueStrings(existing + additions).joined(separator: ":")
        return result
    }

    /// Ask Bundle for the nested resource directory; `Bundle.module` searches the app top level and build path, then traps.
    private static func bundledHelper(named name: String, resourceRoot: URL) -> URL {
        let nestedBundle = resourceRoot.appendingPathComponent(
            "NativeAgent_NativeAgentApp.bundle",
            isDirectory: true
        )
        guard let resources = Bundle(url: nestedBundle)?.resourceURL else {
            // Report the packaged helper path even when its bundle cannot be read.
            return nestedBundle.appendingPathComponent("Contents/Resources/\(name)")
        }
        return resources.appendingPathComponent(name)
    }

    private static func firstExecutable(_ candidates: [URL], fileManager: FileManager) -> URL? {
        for candidate in unique(candidates).map(\.standardizedFileURL) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
