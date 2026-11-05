import Foundation

// Blueprint: | `CodexHandoff.swift` | `CodexHandoff.path`; One explicit handoff identity. |

public enum CodexHandoff {
    /// Explicit process configuration selects the exact file; otherwise use the canonical cross-project handoff.
    public static var path: URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_HANDOFF_PATH"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CODEX_HANDOFF_FOR_AGENT.md")
    }
}
