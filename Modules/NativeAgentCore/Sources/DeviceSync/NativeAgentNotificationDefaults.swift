import Foundation
import PersistenceCore
import PersonaEngine

/// The title every notification to the Mac or the phone carries: her display
/// name unless the caller gave a real one.
public enum NativeAgentNotificationDefaults {
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
