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
    /// 2026-09-26: per bundle for the shipped installs too. Both shared one
    /// socket and token, so the second to launch unlinked the first's listener.
    /// The relay derives this from its own bundle; Chrome's one host name
    /// picks the relay via the manifest's owner.
    public var chromeSocket: URL {
        home.appendingPathComponent(".config/" + bundleIdentifier + "/chrome.sock")
    }
    /// 2026-09-26: each install's own FIXED loopback ports, like its Chrome
    /// socket. The primary install keeps 8770 (Mac control), 8771 (bridge) and
    /// 8766 (browser IPC); another bundle, or an install marked secondary,
    /// gets its own set from its bundle id, so two installs never contend.
    /// A taken port fails loudly; nothing hops. Clients read the descriptor.
    public struct LoopbackPorts: Sendable, Equatable {
        public let macControl: UInt16
        public let bridge: UInt16
        public let browserIPC: UInt16
    }
    public func loopbackPorts(
        secondary: Bool = UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall")
    ) -> LoopbackPorts {
        guard secondary || !usesLegacyPaths else { return LoopbackPorts(macControl: 8770, bridge: 8771, browserIPC: 8766) }
        // FNV-1a over the bundle id: the same set every launch and build, in
        // 18700-19696, below macOS's ephemeral range.
        var hash: UInt32 = 2_166_136_261
        for byte in bundleIdentifier.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let base = UInt16(18_700 + Int(hash % 100) * 10)
        return LoopbackPorts(macControl: base, bridge: base + 1, browserIPC: base + 6)
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
        // Adopt a pre-ownership relay from an earlier location of this app.
        guard let path = manifest["path"] as? String, path.hasPrefix("/") else { return false }
        let oldRelay = URL(fileURLWithPath: path).standardizedFileURL
        if oldRelay.resolvingSymlinksInPath() == relay.resolvingSymlinksInPath() { return true }
        guard oldRelay.lastPathComponent == "NativeAgentChromeRelay",
              oldRelay.deletingLastPathComponent().lastPathComponent == "MacOS",
              oldRelay.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { return false }
        let app = oldRelay.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Only when that app is gone or is this same bundle: another installed
        // variant's manifest is not ours to replace or delete.
        let other = Bundle(url: app)?.bundleIdentifier
        return app.pathExtension == "app" && app.deletingPathExtension().lastPathComponent.hasPrefix("NativeAgent")
            && (other == nil || other == bundleIdentifier)
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
