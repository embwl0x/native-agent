import Foundation
import NativeAgentShared
import ChatTurnRuntime
import AgentWorkspace
import ChatToolParsing
import AgentLinkTransport
import NativeAgentCore
import PersistenceCore
import AgentConversations
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting
import CryptoKit
import SQLite3
// Blueprint: | `AgentContactTaskValues.swift` | A2A task, event and turn result vocabulary |
public enum AgentContactTaskState: String, Codable, Sendable {
    case submitted, working, inputRequired = "input-required", completed, failed, canceled, stopped
    public var terminal: Bool { self == .completed || self == .failed || self == .canceled || self == .stopped }
}
public struct AgentContactTask: Codable, Sendable {
    public var lifeID: String?
    public let id: String
    public let context: String
    public let owner: String
    public var state: AgentContactTaskState = .submitted
    public var text = ""
    public var parts: [AgentContactPart] = []
    public var detail: String?
    public var failure: ProviderFailure.Report?
    public var updated = Date()
    public var canonicalSession: String?
    public var canonicalRunID: String?
    public var acceptedOutputModes: [String]?
    public var toolResult: JSONValue?
    public var delegatedCompletions: [String: AgentContactPart]?
    public var approvalIDs: Set<String>?
    public var replyPayloadExpired: Bool?
    public var delegatedCompletionDigests: [String: String]?
    /// Its registered callbacks, by config id: durable before acceptance.
    public var callbacks: [String: AgentContactCallback]?
    var owesCallbacks: Bool {
        callbacks?.values.contains { $0.delivered != state.rawValue } == true
    }
    var needsReplyRecovery: Bool {
        // Older receipts conflated file recovery with the canonical turn outcome.
        !state.terminal || (state == .failed && detail == "The saved reply's files could not be fully recovered. Do not resend automatically.")
    }
    var hasReplyPayload: Bool {
        !text.isEmpty || !parts.isEmpty || toolResult != nil || failure != nil
            || delegatedCompletions?.isEmpty == false
    }
}
public enum AgentContactEvent: Sendable {
    case snapshot(AgentContactTask)
    case status(AgentContactTask, final: Bool)
    case artifact(task: AgentContactTask, artifactID: String, parts: [AgentContactPart], append: Bool, last: Bool)
}
struct AgentContactTurn: Sendable {
    let taskID: String
    let context: String
    let requestID: String
    let principal: AgentBridgePrincipal
    let parts: [AgentContactPart]
    var bindRun: @Sendable (String, String) async throws -> Void = { _, _ in }
    /// Its input already saved in the conversation: a restart left it queued.
    var accepted: EnqueuedUserMessage? = nil
}
enum AgentContactProgress: Sendable {
    case working
    case text(String)
    case waiting
    case approval(String)
}
struct AgentContactOutcome: Sendable {
    var state: AgentContactTaskState
    var parts: [AgentContactPart]
    var detail: String? = nil
    var failure: ProviderFailure.Report? = nil
}
