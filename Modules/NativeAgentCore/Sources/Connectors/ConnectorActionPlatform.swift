import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
import MacAssistantStatus
import AttentionRouting

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

/// Host bindings for platform access and already-owned runtime read projections.
public protocol ConnectorActionPlatform: Sendable {
    func attentionRouter() -> AttentionRouter
    func macAction(_ action: ConnectorPlatformAction, input: [String: JSONValue]) async throws -> JSONValue
    func spotlight(input: [String: JSONValue]) async throws -> MacControlResult
    func postMessage(title: String, body: String) async -> [String: JSONValue]
    func macAssistantStatusClient() -> any MacAssistantStatusClient
    func statusEvidence(actionID: String) async -> ConnectorActionStatusEvidence?
    func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String)
}
