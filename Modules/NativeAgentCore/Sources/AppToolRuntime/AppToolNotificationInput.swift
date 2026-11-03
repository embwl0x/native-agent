import Foundation
import PersistenceCore
import DeviceSync
// Blueprint: | `AppToolNotificationInput.swift` | `NativeAgentNotificationDefaults`: `parseInput` |

extension NativeAgentNotificationDefaults {
    /// The one parser every notify entry point (chat shim, core bridge,
    /// connector action) reads its title and body with, so they cannot drift
    /// on the canonical message key or how they refuse.
    public static func parseInput(
        _ input: [String: JSONValue],
        toolName: String
    ) throws -> (title: String, message: String) {
        let resolvedTitle = Self.title(input["title"]?.scalarText)
        // Refusals distinguish a blank message body from a missing one.
        guard let message = input["message"]?.scalarText else {
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
            return "\(tool) requires a 'message' argument"
        case .emptyMessage(let tool):
            return "\(tool) received 'message' but it was empty — send the notification body text"
        }
    }
}
