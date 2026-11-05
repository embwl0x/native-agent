import AgentWorkspace
import NativeAgentShared
import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnContracts
import Experiences
import TurnTrace
// Blueprint: | `AgentConversationDelivery.swift` | Delivery states require retained evidence. |

extension AgentConversationRecord {
    /// An answer is owed unless explicitly waived; wording cannot waive it.
    public var awaitsReply: Bool { expectsReply != false }
}

/// Waiting retains an owed answer until its recorded deadline; terminal unknowns cannot claim non-delivery.
public enum AgentConversationDelivery: String, Sendable {
    case sending, waiting, delivered, read, answered, failed, notDelivered
    /// A reply deadline says nothing about delivery.
    case unanswered

    public static func of(_ row: AgentConversationRecord, read: Bool) -> Self {
        if row.phase == "sending" { return .sending }
        if row.sendFailed { return .failed }
        if row.sendStatus == "held" { return .waiting }
        if row.phase != "sending", case .object(let receipt)? = row.receipt, receipt["reply_state"] == .string("no_reply_expired") {
            return receipt["sent"] == .bool(false) ? .notDelivered : .unanswered
        }
        if case .object(let receipt)? = row.receipt, receipt["sent"] == .bool(false) { return .notDelivered }
        if row.phase == "ready", row.exchanges?.last(where: { $0.id == row.operationID })?.reply != nil { return .answered }
        switch row.phase {
        case "attention":
            if case .object(let receipt)? = row.receipt, receipt["status"] == .string(
                "outcome_unknown") { return AgentConversationSession.unsettledAttention(row) ? .waiting : .failed }
            if case .object(let receipt)? = row.receipt, receipt["error"] != nil { return .notDelivered }
            return row.awaitsReply ? .failed : (accepted(row, read: read) ? .delivered : .waiting)
        case "waiting": return .waiting
        default: return accepted(row, read: read) ? (read ? .read : .delivered) : .waiting
        }
    }

    package static func answersLive(peer: AgentPeerContact?) -> Bool {
        guard let peer, peer.ability == nil else { return false }
        switch peer.transport {
        case .acp, .nativeAgent, .a2a, .desktopChat: return true
        case .mcpHost: return !ChatGPTDotIPCTransport.owns(peer)
        default: return false
        }
    }

    public static func accepted(_ row: AgentConversationRecord, read: Bool = false) -> Bool {
        if row.phase != "sending", row.sendFailed { return false }
        if read || row.exchanges?.last(where: { $0.id == row.operationID })?.reply != nil { return true }
        let value = row.sendEvidence
        if let message = row.readInput?["message_id"], case .array(let ids)? = value["accepted_message_ids"], ids.contains(message),
           case .string(let state)? = value["run_status"] ?? value["status"] ?? value["state"],
           ["running", "working", "completed", "succeeded", "done", "answered", "replied"].contains(state) { return true }
        return value["read"] == .bool(true) || value["accepted"] == .bool(true)
            || ["reply", "answer"].contains { if case .string(let text)? = value[$0] { !text.isEmpty } else { false } }
    }

}

/// The conversation operation's modes and dependencies, handed to its dispatch callback.
public struct AgentConversationContext: Sendable {
    public var isInternalRead = false
    public var returnsHistory = true
    public var dryRun = false
    public var liveTarget: AgentConversationLiveTarget?
    package var helperDoor: HelperContact.Door?

    public init() {}

    public var internalRead: Self {
        var operation = self
        operation.isInternalRead = true
        return operation
    }

    public var withoutHistory: Self {
        var operation = self
        operation.returnsHistory = false
        return operation
    }

    public func live(_ target: AgentConversationLiveTarget) -> Self {
        var operation = self
        operation.liveTarget = target
        return operation
    }
}
