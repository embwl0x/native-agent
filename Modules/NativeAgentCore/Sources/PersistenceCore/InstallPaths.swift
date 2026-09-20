import Foundation

/// 2026-09-18: one owner for install-owned paths outside the data root. The
/// shipped installs keep their established rendezvous; only other bundle ids
/// namespace tokens, sockets, caches and entries in another app.
public struct InstallPaths: Sendable {
    public static let privateBundleIdentifier = "com.example.nativeagent.mac"
    public static let current: InstallPaths = {
        // Bundled helpers live beside the app executable in Contents/MacOS.
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return InstallPaths(bundleIdentifier: currentAppBundleIdentifier()
            ?? app.flatMap { $0.pathExtension == "app" ? Bundle(url: $0)?.bundleIdentifier : nil })
    }()
    public let bundleIdentifier: String
    public let home: URL

    public init(bundleIdentifier: String? = currentAppBundleIdentifier(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.bundleIdentifier = bundleIdentifier ?? Self.privateBundleIdentifier
        self.home = home
    }

    public var usesLegacyPaths: Bool {
        bundleIdentifier == Self.privateBundleIdentifier || bundleIdentifier == "io.github.embwl0x.nativeagent.mac"
    }
    public func name(_ legacy: String) -> String {
        usesLegacyPaths ? legacy : legacy + "-" + bundleIdentifier
    }
    public var bridgeConfigRelativePath: String { usesLegacyPaths ? ".config" : ".config/" + bundleIdentifier }
    public var bridgeConfigRoot: URL { home.appendingPathComponent(bridgeConfigRelativePath, isDirectory: true) }
    public var chromeSocket: URL {
        usesLegacyPaths
            ? home.appendingPathComponent("Library/Application Support/NativeAgent/chrome-control.sock")
            : bridgeConfigRoot.appendingPathComponent("chrome.sock")
    }
    public var chromeManifest: URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.nativeagent.chrome.json")
    }
    public var agentHostEntryName: String {
        // TOML bare keys cannot contain dots. Escape underscores first.
        name("nativeagent").replacingOccurrences(of: "_", with: "__").replacingOccurrences(of: ".", with: "_d")
    }
    public func bridgeConfigRoot(dataRoot: URL, defaultRoot: URL? = nil,
                                 secondary: Bool = UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall")) -> URL {
        // Relocated test/dev roots still stay self-contained, including readers.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NATIVE_AGENT_DATA_ROOT")
        return !secondary && dataRoot.resolvingSymlinksInPath().path == (defaultRoot ?? defaultDataRoot(environment: environment)).resolvingSymlinksInPath().path
            ? bridgeConfigRoot : dataRoot.appendingPathComponent("bridge-config", isDirectory: true)
    }
    public func bridgeDiscoveryDirectory(dataRoot: URL, defaultRoot: URL? = nil,
                                         secondary: Bool = UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall")) -> URL {
        let root = bridgeConfigRoot(dataRoot: dataRoot, defaultRoot: defaultRoot, secondary: secondary)
        // 2026-09-18: relocated shipped installs published directly under their
        // data root; their readers' bridge-config directory is a separate path.
        return (usesLegacyPaths && root != bridgeConfigRoot ? dataRoot.standardizedFileURL : root)
            .appendingPathComponent("claude-bridge", isDirectory: true)
    }
    public func ownsChromeManifest(_ manifest: [String: Any], relay: URL) -> Bool {
        if let owner = manifest["nativeagent_bundle_id"] as? String { return owner == bundleIdentifier }
        // A pre-ownership manifest can only be adopted by the relay it names.
        return (manifest["path"] as? String).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath() == relay.resolvingSymlinksInPath()
        } ?? false
    }

    public func bridgeEnvironment(configRoot: URL) -> [String: String] {
        let claude = configRoot.appendingPathComponent("claude-bridge")
        return [
            "NATIVE_AGENT_CLAUDE_BRIDGE_DIR": claude.path,
            "NATIVE_AGENT_RETURN_BRIDGE_DIR": claude.path,
            "NATIVE_AGENT_CODEX_BRIDGE_DESCRIPTOR_PATH": claude.appendingPathComponent("bridge.json").path,
            "NATIVE_AGENT_CODEX_BRIDGE_TOKEN_PATH": claude.appendingPathComponent("token").path,
            "NATIVE_AGENT_CODEX_WAKEUP_CONFIG": configRoot.appendingPathComponent("codex-nativeagent-bridge/wakeup.json").path,
            "NATIVE_AGENT_OMP_BRIDGE_DIR": configRoot.appendingPathComponent("omp-bridge").path,
        ]
    }
}
