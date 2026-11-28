import Foundation
import NativeAgentCore
import PersistenceCore
import MacNerves
// Blueprint: | `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `spotlight`, `postMessage`, `macAssistantStatusClient` |

public protocol ConnectorActionPlatform: Sendable {
    func spotlight(input: [String: JSONValue], turn: Turn) async throws -> MacControlResult
    func postMessage(_ note: NativeAgentNotificationDefaults.Note, turn: Turn) async -> [String: JSONValue]
    func macAssistantStatusClient() -> any MacAssistantStatusClient
}
