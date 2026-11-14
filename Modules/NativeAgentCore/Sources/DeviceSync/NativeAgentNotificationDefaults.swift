import Foundation
import PersistenceCore
import PersonaEngine

// Blueprint: | `NativeAgentNotificationDefaults.swift` | `NativeAgentNotificationDefaults`; Shared title resolution. |

/// Use the agent's display name unless the caller supplied a nonblank title.
public enum NativeAgentNotificationDefaults {
    /// One notification as a call gives it: its title, optional subtitle and body travel together to every door that shows it.
    public struct Note: Sendable, Equatable {
        public let title: String
        /// Shown between title and body; nil when the call gave none.
        public let subtitle: String?
        public let message: String
        public init(title: String, subtitle: String? = nil, message: String) {
            self.title = title
            self.subtitle = subtitle.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            self.message = message
        }
    }

    public static func agentDisplayName(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> String {
        PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
    }

    public static func title(_ raw: String?, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> String {
        let fallback = agentDisplayName(dataRoot: dataRoot)
        guard let raw else { return fallback }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        if genericNotificationTitles.contains(trimmed.lowercased()) {
            return fallback
        }
        return trimmed
    }

    private static let genericNotificationTitles: Set<String> = [
        "agent",
        "ai",
        "assistant",
        "custom",
        "female",
        "male",
        "native agent",
        "native agent app",
        "nativeagent",
        "nativeagentapp",
    ]
}
