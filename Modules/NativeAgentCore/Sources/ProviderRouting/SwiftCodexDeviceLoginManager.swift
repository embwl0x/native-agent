import Foundation
// Blueprint: | `SwiftCodexDeviceLoginManager.swift` | `SwiftCodexDeviceLoginManager` enum; CLI executable readiness |

public enum SwiftCodexDeviceLoginManager {
    static var executableSearchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    public static func augmentedPath(_ existing: String?) -> String {
        var parts = (existing ?? "").split(separator: ":").map(String.init)
        for addition in executableSearchDirectories where !parts.contains(addition) {
            parts.append(addition)
        }
        return parts.joined(separator: ":")
    }

    public static func resolveCodexExecutable(environment: [String: String]) throws -> URL {
        let fm = FileManager.default
        if let override = environment["NATIVE_AGENT_CODEX_BIN"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let path = environment["PATH"] ?? augmentedPath(nil)
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw NSError(domain: "NativeAgentSwiftOnly", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Could not find an executable codex CLI. Install codex or set NATIVE_AGENT_CODEX_BIN."
        ])
    }
}
