import Foundation
// Blueprint: | `SwiftCodexDeviceLoginManager.swift` | `CodexExecutable`: inherited-first PATH and explicit-override executable selection shared by readiness and process execution |
public enum CodexExecutable {
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

    public static func resolveCodexExecutable(environment: [String: String], program: String? = nil) throws -> URL {
        let fm = FileManager.default
        let override = environment["NATIVE_AGENT_CODEX_BIN"].flatMap { $0.isEmpty ? nil : $0 }
        let name = ((program ?? override ?? "codex") as NSString).expandingTildeInPath
        let candidates = name.contains("/") ? [URL(fileURLWithPath: name)]
            : augmentedPath(environment["PATH"]).split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        if let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) { return executable }
        throw NSError(domain: "NativeAgentSwiftOnly", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Could not find an executable Codex CLI at '\(name)'. Install Codex or set NATIVE_AGENT_CODEX_BIN."
        ])
    }
}
