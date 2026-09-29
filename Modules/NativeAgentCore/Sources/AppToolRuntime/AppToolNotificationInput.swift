import Foundation
import PersistenceCore
import DeviceSync

extension NativeAgentNotificationDefaults {
    /// The one parser every notify entry point (chat shim, core bridge,
    /// connector action) reads its title and body with, so they cannot drift
    /// on which keys they accept or how they refuse. An empty-string field is
    /// treated as absent, so `"message": ""` falls through to `body`/`text`.
    public static func parseInput(
        _ input: [String: JSONValue],
        toolName: String
    ) throws -> (title: String, message: String) {
        let input = input.filter { $0.value != .string("") }
        let resolvedTitle = Self.title(AppToolExecutor.inputString(input["title"]))
        // D2 (2026-09-11 tools review): a present-but-blank body and a missing
        // one are different faults; the refusal names the one that happened.
        guard let message = AppToolExecutor.inputString(input["message"])
            ?? AppToolExecutor.inputString(input["body"])
            ?? AppToolExecutor.inputString(input["text"]) else {
            throw NotificationInputError.missingMessage(toolName)
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotificationInputError.emptyMessage(toolName)
        }
        return (resolvedTitle, message)
    }
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
