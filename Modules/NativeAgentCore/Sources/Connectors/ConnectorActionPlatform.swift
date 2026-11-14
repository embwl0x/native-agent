import Foundation
import DeviceSync
import NativeAgentCore
import PersistenceCore
import MacControl
import MacIntegration
// Blueprint: | `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `spotlight`, `postMessage`, `statusEvidence`, `runGit` |

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
    func runGit(_ arguments: [String], repoRoot: URL, timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String)
}
