import Foundation

// Blueprint: | `CodexHandoff.swift` | `CodexHandoff.path`: one explicit handoff identity for connector reads and cognition/file wakes; no filesystem-dependent selection |

public enum CodexHandoff {
    /// An explicit process configuration selects its exact file. Otherwise
    /// User's cross-project handoff has this single canonical identity.
    public static var path: URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_CODEX_HANDOFF_PATH"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CODEX_HANDOFF_FOR_AGENT.md")
    }
}
