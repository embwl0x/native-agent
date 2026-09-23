import Foundation
import PersistenceCore
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

    /// The one parser every notify entry point (chat shim, core bridge,
    /// connector action) reads its title and body with, so they cannot drift
    /// on which keys they accept or how they refuse. An empty-string field is
    /// treated as absent, so `"message": ""` falls through to `body`/`text`.
    static func parseInput(
        _ input: [String: JSONValue],
        toolName: String
    ) throws -> (title: String, message: String) {
        let input = input.filter { $0.value != .string("") }
        let resolvedTitle = Self.title(NativeClient.connectorInputString(input["title"]))
        // D2 (2026-09-11 tools review): a present-but-blank body and a missing
        // one are different faults; the refusal names the one that happened.
        guard let message = NativeClient.connectorInputString(input["message"])
            ?? NativeClient.connectorInputString(input["body"])
            ?? NativeClient.connectorInputString(input["text"]) else {
            throw NotificationInputError.missingMessage(toolName)
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotificationInputError.emptyMessage(toolName)
        }
        return (resolvedTitle, message)
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

private enum NotificationInputError: LocalizedError {
    case missingMessage(String)
    case emptyMessage(String)

    var errorDescription: String? {
        switch self {
        case .missingMessage(let tool):
            return "\(tool) requires a 'message' argument (a 'body' or 'text' argument is also accepted)"
        case .emptyMessage(let tool):
            return "\(tool) received 'message' but it was empty — send the notification body text"
        }
    }
}
