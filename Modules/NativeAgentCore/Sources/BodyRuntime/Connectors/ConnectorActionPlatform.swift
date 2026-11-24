import Foundation
import NativeAgentCore
import PersistenceCore
import MacNerves
// Blueprint: | `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `spotlight`, `postMessage`, `statusEvidence` |

public struct ConnectorActionStatusEvidence: Sendable {
    public let connectorStatus: String?
    public let authState: String?
    public let enabled: Bool?

    public init(connectorStatus: String?, authState: String?, enabled: Bool?) {
        self.connectorStatus = connectorStatus
        self.authState = authState
        self.enabled = enabled
    }
}

public protocol ConnectorActionPlatform: Sendable {
    func spotlight(input: [String: JSONValue], turn: Turn) async throws -> MacControlResult
    func postMessage(_ note: NativeAgentNotificationDefaults.Note, turn: Turn) async -> [String: JSONValue]
    func macAssistantStatusClient() -> any MacAssistantStatusClient
    func statusEvidence(actionID: String) async throws -> ConnectorActionStatusEvidence?
}
