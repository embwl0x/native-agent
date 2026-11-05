import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import MacIntegration
import AttentionRouting
// Blueprint: | `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `attentionRouter`, `macAction` |

public enum ConnectorPlatformAction: Sendable {
    case calendarListUpcoming, remindersListDueToday, mailListRecent, messagesRecentThreads
    case notesListRecent, notesSearch, contactsSearch
}

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
    func attentionRouter() -> AttentionRouter
    func macAction(_ action: ConnectorPlatformAction, input: [String: JSONValue], turn: Turn) async throws -> JSONValue
    func spotlight(input: [String: JSONValue], turn: Turn) async throws -> MacControlResult
    func postMessage(title: String, body: String, turn: Turn) async -> [String: JSONValue]
    func macAssistantStatusClient() -> any MacAssistantStatusClient
    func statusEvidence(actionID: String) async throws -> ConnectorActionStatusEvidence?
    func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String)
}
