import Foundation
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `InstallPaths.swift` | Install-owned paths, public release preparation and login-item location admission |

/// Owns paths outside the data root, preserving shipped rendezvous names and namespacing other bundle ids.
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
    /// Every bundle owns its Chrome socket; the manifest's owner selects the relay.
    public var chromeSocket: URL {
        home.appendingPathComponent(".config/" + bundleIdentifier + "/chrome.sock")
    }
    /// Install ports are fixed; a collision fails without hopping, and clients read the descriptor.
    public struct LoopbackPorts: Sendable, Equatable {
        public let bridge: UInt16
        public let browserIPC: UInt16
    }
    public func loopbackPorts(
        secondary: Bool = UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall")
    ) -> LoopbackPorts {
        guard secondary || !usesLegacyPaths else { return LoopbackPorts(bridge: 8771, browserIPC: 8766) }
        // FNV-1a over the bundle id: the same set every launch and build, in
        // 18700-19696, below macOS's ephemeral range.
        var hash: UInt32 = 2_166_136_261
        for byte in bundleIdentifier.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let base = UInt16(18_700 + Int(hash % 100) * 10)
        return LoopbackPorts(bridge: base + 1, browserIPC: base + 6)
    }
    public var chromeManifest: URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.nativeagent.chrome.json")
    }
    /// A secondary install names its own entry, like its ports, so two installs
    /// on one Mac never collide in another app's settings.
    public func agentHostEntryName(
        secondary: Bool = UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall")
    ) -> String {
        // TOML bare keys cannot contain dots. Escape underscores first.
        (secondary ? "nativeagent-" + bundleIdentifier : name("nativeagent"))
            .replacingOccurrences(of: "_", with: "__").replacingOccurrences(of: ".", with: "_d")
    }
    /// Bridge protocol owners keep private inboxes/jobs, quarantine bytes and
    /// worktree pointers here; excluded from app backup/export/phone file sync.
    /// Contact status and canonical transcript projections are separate.
    /// PrivacyMap resolves each bridge directory through this same root.
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
        bridgeConfigRoot(dataRoot: dataRoot, defaultRoot: defaultRoot, secondary: secondary)
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
            "NATIVE_AGENT_RETURN_BRIDGE_DIR": claude.path,
            "NATIVE_AGENT_CODEX_BRIDGE_DESCRIPTOR_PATH": claude.appendingPathComponent("bridge.json").path,
            "NATIVE_AGENT_CODEX_BRIDGE_TOKEN_PATH": claude.appendingPathComponent("token").path,
            "NATIVE_AGENT_CODEX_WAKEUP_CONFIG": configRoot.appendingPathComponent("codex-nativeagent-bridge/wakeup.json").path,
            "NATIVE_AGENT_OMP_BRIDGE_DIR": configRoot.appendingPathComponent("omp-bridge").path,
        ]
    }

    public static let publicReleaseDataMarker = "public_release_data_root.json"

    public static func allowsLoginItem(bundlePath: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let userApplications = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path
        return ["/Applications", userApplications].contains { NativeAgentWorkspaceRoot.relativePath(path, under: $0)?.isEmpty == false }
    }

    public enum PublicReleaseDataRootPreparationResult: Sendable {
        case notNeeded
        case prepared(String)
        case failed(String)
    }

    /// Mark the public release in place, preserving all existing user data.
    @discardableResult
    public static func preparePublicReleaseDataRootIfNeeded() -> PublicReleaseDataRootPreparationResult {
        let fm = FileManager.default
        // Round 3: empty env = unset (Core resolver parity).
        guard (ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"] ?? "").isEmpty else { return .notNeeded }
        guard isPublicReleaseBundle else { return .notNeeded }

        let support = libraryAppSupportFallback().standardizedFileURL
        let root = defaultDataRoot().standardizedFileURL
        guard root.path == support.path else { return .notNeeded }

        let marker = root
            .appendingPathComponent("install", isDirectory: true)
            .appendingPathComponent(publicReleaseDataMarker)
        if fm.fileExists(atPath: marker.path) {
            return .notNeeded
        }

        do {
            try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            var payload: [String: Any] = [
                "markerVersion": 1,
                "channel": "public-release",
                "createdAt": NativeTimestampFormat.plainZulu(Date()),
                "reason": "public_release_marker_written_in_place",
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "bundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "bundleShortVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            ]
            if let resourcesURL = Bundle.main.resourceURL,
               let buildSHA = try? String(
                contentsOf: resourcesURL.appendingPathComponent("VERSION_SHA"),
                encoding: .utf8
               ).trimmingCharacters(in: .whitespacesAndNewlines),
               !buildSHA.isEmpty {
                payload["buildSHA"] = buildSHA
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: marker, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)

            let message = "[paths] public release marker written in place at \(root.path); existing data retained"
            print(message)
            return .prepared(message)
        } catch {
            let message = "[paths] public release marker could not be written: \(error.localizedDescription)"
            print(message)
            return .failed(message)
        }
    }

    /// True only for a distributed public build: no REPO_PATH dev stamp, a real
    /// .app bundle, and a VERSION resource. Dev installs from install_app.sh are
    /// always stamped, so they can never read as public-release. Gates the
    /// data-root marker and the first-run welcome greeting.
    public static let isPublicReleaseBundle: Bool = {
        let fm = FileManager.default
        guard let resourcesURL = Bundle.main.resourceURL else { return false }
        if fm.fileExists(atPath: resourcesURL.appendingPathComponent("REPO_PATH").path) {
            return false
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return fm.fileExists(atPath: resourcesURL.appendingPathComponent("VERSION").path)
    }()
}
