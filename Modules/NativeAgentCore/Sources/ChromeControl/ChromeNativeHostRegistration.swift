import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
// Blueprint: | `ChromeNativeHostRegistration.swift` | `ChromeNativeHostRegistration`: bundled relay identity and native-host manifest install/uninstall; directory-locked ownership checks preserve the registered install and shared extension origin |

public enum ChromeNativeHostRegistration {
    static let hostID = "com.nativeagent.chrome"
    /// Registration and relay authentication share one extension identity.
    static let extensionID = ChromeHostIdentity.extensionID

    /// The bundled registered relay is the control socket's required peer.
    static func bundledRelayURL() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NativeAgentChromeRelay")
    }

    static func install(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        relayURL: URL? = nil,
        bundleIdentifier: String? = currentAppBundleIdentifier()
    ) throws {
        let relay = relayURL ?? bundledRelayURL()
        guard relay.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: relay.path) else {
            throw ChromeControlRuntimeError.relayUnavailable
        }
        let paths = InstallPaths(bundleIdentifier: bundleIdentifier, home: home)
        let manifest: [String: Any] = [
            "name": hostID,
            "description": "NativeAgent Chrome transport relay",
            "path": relay.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
            "nativeagent_bundle_id": paths.bundleIdentifier,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try update(paths: paths, relay: relay) { destination in
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: destination)
        }
    }

    /// Only Chrome's registered install may refresh the extension it runs.
    public static func ownsOrUnclaimed() -> Bool {
        let paths = InstallPaths.current
        guard FileManager.default.fileExists(atPath: paths.chromeManifest.path) else { return true }
        guard let data = try? Data(contentsOf: paths.chromeManifest),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return paths.ownsChromeManifest(manifest, relay: bundledRelayURL())
    }

    static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          relayURL: URL? = nil, bundleIdentifier: String? = currentAppBundleIdentifier()) throws {
        let paths = InstallPaths(bundleIdentifier: bundleIdentifier, home: home)
        guard FileManager.default.fileExists(atPath: paths.chromeManifest.path) else { return }
        try update(paths: paths, relay: relayURL ?? bundledRelayURL()) { destination in
            try FileManager.default.removeItem(at: destination)
        }
    }

    private static func update(paths: InstallPaths, relay: URL, _ write: (URL) throws -> Void) throws {
        let directory = paths.chromeManifest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The directory lock serializes ownership checks and atomic manifest replacement.
        let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if FileManager.default.fileExists(atPath: paths.chromeManifest.path) {
            let data = try Data(contentsOf: paths.chromeManifest)
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  paths.ownsChromeManifest(manifest, relay: relay) else { return }
        }
        try write(paths.chromeManifest)
    }
}
