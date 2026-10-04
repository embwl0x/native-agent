import Foundation
import PersistenceCore
import Darwin

/// Deterministic discovery for the external coding organs NativeAgent may
/// invoke. This owner discovers only local executables and bundled helper
/// resources; it does not authenticate, install software, grant authority, or
/// infer that a subprocess result is verified work.
public enum AgentBridgeRuntime {
    public struct Readiness: Sendable, Equatable {
        public let helper: URL?
        public let runtime: URL?
        public let cli: URL?
        public let returnPath: ReturnPathReadiness

        public var readyToAttempt: Bool {
            helper != nil && runtime != nil && cli != nil
        }

        public var readyForAsyncRoundTrip: Bool {
            readyToAttempt && returnPath.isReady
        }
    }

    public struct ReturnPathReadiness: Sendable, Equatable {
        public let isReady: Bool
        public let reason: String
        public let tokenPresent: Bool
        public let descriptorPresent: Bool
        public let endpoint: URL?

        public init(
            isReady: Bool,
            reason: String,
            tokenPresent: Bool,
            descriptorPresent: Bool,
            endpoint: URL?
        ) {
            self.isReady = isReady
            self.reason = reason
            self.tokenPresent = tokenPresent
            self.descriptorPresent = descriptorPresent
            self.endpoint = endpoint
        }
    }

    public static func codexHelperURL(override: URL? = nil, dataRoot: URL) -> URL? {
        helperURL(named: "codex_thread_wakeup.js", override: override, dataRoot: dataRoot)
    }

    public static func ompHelperURL(override: URL? = nil, dataRoot: URL) -> URL? {
        helperURL(named: "omp_thread_wakeup.js", override: override, dataRoot: dataRoot)
    }

    /// The expected helper when it is a readable regular file, else nil (the
    /// caller reports `expectedHelperPath` in its helper_not_found receipt).
    public static func helperURL(
        named name: String,
        override: URL? = nil,
        dataRoot: URL,
        bundleResourceRoot: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        let path = expectedHelperPath(
            named: name, override: override, dataRoot: dataRoot, bundleResourceRoot: bundleResourceRoot)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path.path),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return nil
        }
        return path
    }

    /// Where a wake helper lives: one path per build kind, no search. When the
    /// data root sits in a NativeAgent checkout (the REPO_PATH dev install, or
    /// a run from the repo) the checkout's `script/` is the helper, so edits
    /// apply without a rebuild. Any other install runs the copy shipped in the
    /// app's resource bundle. `override` is the dispatcher's injection seam.
    public static func expectedHelperPath(
        named name: String,
        override: URL? = nil,
        dataRoot: URL,
        bundleResourceRoot: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
    ) -> URL {
        if let override { return override.standardizedFileURL }
        if let checkout = resolveSandboxRepoRoot(dataRoot: dataRoot) {
            return checkout.appendingPathComponent("script/\(name)").standardizedFileURL
        }
        return bundledHelper(named: name, resourceRoot: bundleResourceRoot).standardizedFileURL
    }

    /// The configured agent and user names from the persona profile, for the
    /// wake helpers' prompts and receipts. Nothing shipped names a specific
    /// agent; an install without a profile yet gets "the agent" / "the user".
    public static func configuredNames(dataRoot: URL) -> (agent: String, user: String) {
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        var agent = "the agent", user = "the user"
        if let data = try? Data(contentsOf: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let n = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { agent = n }
            if let n = (object["userName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { user = n }
        }
        return (agent, user)
    }

    public static func executableURL(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let override: String? = switch name {
        case "codex": environment["NATIVE_AGENT_CODEX_BIN"] ?? environment["CODEX_BIN"]
        case "claude": environment["NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN"]
        case "omp": environment["NATIVE_AGENT_OMP_WAKE_BIN"] ?? environment["OMP_BIN"]
        case "node": environment["NATIVE_AGENT_BRIDGE_NODE_BIN"]
        default: nil
        }

        var directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        directories.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".claude/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".codex/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
        ])

        var candidates = override.map { [URL(fileURLWithPath: $0)] } ?? []
        if name == "codex" {
            candidates.append(homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex"))
            candidates.append(homeDirectory.appendingPathComponent("Desktop/Codex.app/Contents/Resources/codex"))
            candidates.append(URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"))
        }
        candidates.append(contentsOf: unique(directories).map { $0.appendingPathComponent(name) })

        if name == "node" {
            let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            let versionDirectories = ((try? fileManager.contentsOfDirectory(
                at: nvmVersions,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
            candidates.append(contentsOf: versionDirectories.map { $0.appendingPathComponent("bin/node") })
        }
        return firstExecutable(candidates, fileManager: fileManager)
    }

    public static func readiness(
        helper: URL?,
        cliName: String,
        bridgeConfigRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Readiness {
        Readiness(
            helper: helper,
            runtime: executableURL(
                named: "node",
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            cli: executableURL(
                named: cliName,
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            returnPath: returnPathReadiness(
                configRoot: bridgeConfigRoot,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        )
    }

    /// Verifies the private discovery pair published by NativeAgent's
    /// loopback coding-organ return listener. This never exposes the bearer or
    /// grants authority; it only proves that a helper has a live, internally
    /// consistent endpoint to return a completed Codex/Claude turn to.
    public static func returnPathReadiness(
        configRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> ReturnPathReadiness {
        let root = configRoot ?? InstallPaths(home: homeDirectory).bridgeConfigRoot
        let directory = root.appendingPathComponent("claude-bridge", isDirectory: true)
        let tokenURL = directory.appendingPathComponent("token")
        let descriptorURL = directory.appendingPathComponent("bridge.json")
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenPresent = !(token?.isEmpty ?? true)
        let descriptorData = try? Data(contentsOf: descriptorURL)
        let descriptorPresent = descriptorData != nil

        func unavailable(_ reason: String, endpoint: URL? = nil) -> ReturnPathReadiness {
            ReturnPathReadiness(
                isReady: false,
                reason: reason,
                tokenPresent: tokenPresent,
                descriptorPresent: descriptorPresent,
                endpoint: endpoint
            )
        }

        guard tokenPresent else { return unavailable("token_missing") }
        guard let descriptorData,
              let descriptor = (try? JSONSerialization.jsonObject(with: descriptorData)) as? [String: Any] else {
            return unavailable("descriptor_missing_or_invalid")
        }
        guard let descriptorToken = descriptor["token"] as? String,
              descriptorToken == token else {
            return unavailable("token_descriptor_mismatch")
        }
        guard let rawURL = descriptor["url"] as? String,
              let endpoint = URL(string: rawURL),
              endpoint.scheme?.lowercased() == "http",
              let host = endpoint.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = endpoint.port,
              (1...65_535).contains(port) else {
            return unavailable("endpoint_not_loopback_http")
        }
        if let descriptorHost = descriptor["host"] as? String,
           descriptorHost.lowercased() != host {
            return unavailable("descriptor_endpoint_mismatch", endpoint: endpoint)
        }
        if let descriptorPort = (descriptor["port"] as? NSNumber)?.intValue,
           descriptorPort != port {
            return unavailable("descriptor_endpoint_mismatch", endpoint: endpoint)
        }
        guard let number = descriptor["processIdentifier"] as? NSNumber else {
            return unavailable("publisher_pid_missing", endpoint: endpoint)
        }
        let pid = pid_t(number.int32Value)
        guard pid > 0 else { return unavailable("publisher_pid_invalid", endpoint: endpoint) }
        errno = 0
        guard Darwin.kill(pid, 0) == 0 || errno == EPERM else {
            return unavailable("publisher_not_running", endpoint: endpoint)
        }
        return ReturnPathReadiness(
            isReady: true,
            reason: "ready",
            tokenPresent: true,
            descriptorPresent: true,
            endpoint: endpoint
        )
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
        // Wake helpers report working/partial/finished to the app's live
        // stream (`/<lane>/live`); off unless the app launched them.
        result["NATIVE_AGENT_WAKE_LIVE"] = base["NATIVE_AGENT_WAKE_LIVE"] ?? "1"
        return result
    }

    /// The helpers ship as SwiftPM resources of the app target, i.e. inside
    /// `Contents/Resources/NativeAgent_NativeAgentApp.bundle`, whose own
    /// resources live under its `Contents/Resources/` on macOS. Ask Bundle
    /// for that resource directory instead of hand-building the path.
    /// `Bundle.module` is not usable here: it belongs to the app target, and
    /// its synthesized accessor only checks the .app top level and the
    /// builder's `.build/` path (then traps).
    private static func bundledHelper(named name: String, resourceRoot: URL) -> URL {
        let nestedBundle = resourceRoot.appendingPathComponent(
            "NativeAgent_NativeAgentApp.bundle",
            isDirectory: true
        )
        guard let resources = Bundle(url: nestedBundle)?.resourceURL else {
            // No readable bundle there, so nothing under it can be read; report
            // where the packaged macOS layout puts the helper.
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
