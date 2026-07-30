import Foundation
import PersonaEngine

enum NativeAgentNotificationDefaults {
    static func agentDisplayName(dataRoot: URL = NativeAgentPaths.dataRoot) -> String {
        PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
    }

    static func title(_ raw: String?, dataRoot: URL = NativeAgentPaths.dataRoot) -> String {
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
