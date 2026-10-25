import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `HelperContact.swift` | Turn-local resident contact door for this install's helper; argument routing grants no authority and the actual send remains below the existing tool gates |

package enum HelperContact {
    package struct Door: Sendable {
        package let name: String
        package let conversationID: String
        package let send: @Sendable (String) async throws -> JSONValue
        package init(name: String, conversationID: String, send: @escaping @Sendable (String) async throws -> JSONValue) {
            self.name = name; self.conversationID = conversationID; self.send = send
        }
    }
    @TaskLocal package static var door: Door?

    package static func matches(_ input: [String: JSONValue]) -> Bool {
        guard let door, case .string(let name)? = input["agent"] else { return false }
        return name.caseInsensitiveCompare(door.name) == .orderedSame
    }

    package static func message(_ input: [String: JSONValue]) async throws -> JSONValue? {
        guard matches(input), let door else { return nil }
        guard Set(input.keys).isSubset(of: ["agent", "text", "conversation_id", "session_id", "__session_id"]),
              input["conversation_id"] == nil || input["conversation_id"] == .string(door.conversationID),
              case .string(let text)? = input["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentConversationStore.Failure(message: "Name the contact and the text to send.")
        }
        return try await door.send(text)
    }
}
