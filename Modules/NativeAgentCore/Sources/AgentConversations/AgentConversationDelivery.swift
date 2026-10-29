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
// Blueprint: | `AgentConversationDelivery.swift` | Conversation delivery and admitted context vocabulary from retained evidence |

extension AgentConversationRecord {
    /// An answer is owed unless explicitly waived; wording cannot waive it.
    public var awaitsReply: Bool { expectsReply != false }
}

/// Where a contact's current send stands, from evidence the lanes already keep: sending → delivered → read → answered, or failed. `waiting` is a send the lane is still carrying, or one handed over whose asked-for answer is still owed,
/// until its recorded reply deadline. `outcome_unknown` follows the session's hold; terminal unknowns fail without claiming non-delivery.
public enum AgentConversationDelivery: String, Sendable {
    case sending, waiting, delivered, read, answered, failed, notDelivered

    /// `read`: the recipient's inbox marked this send read.
    public static func of(_ row: AgentConversationRecord, read: Bool) -> Self {
        if row.phase == "sending" { return .sending }
        if row.sendFailed { return .failed }
        if claudeInbox(row),
           row.exchanges?.last(where: { $0.id == row.operationID })?.reply == nil,
           case .object(let receipt)? = row.receipt,
           (["delivered", "queued", "read"].contains(receipt["status"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "")
            || AgentConversationSession.liveHandOff(row)) {
            return read || receipt["read"] == .bool(true) ? (row.awaitsReply ? .waiting : .read) : .waiting
        }
        if row.phase != "sending", case .object(let receipt)? = row.receipt, receipt["reply_state"] == .string("no_reply_expired") { return .failed }
        if case .object(let receipt)? = row.receipt, receipt["sent"] == .bool(false) { return .notDelivered }
        if row.phase == "ready", row.exchanges?.last(where: { $0.id == row.operationID })?.reply != nil { return .answered }
        switch row.phase {
        case "attention":
            if case .object(let receipt)? = row.receipt, receipt["status"] == .string("outcome_unknown") { return AgentConversationSession.unsettledAttention(row) ? .waiting : .failed }
            if case .object(let receipt)? = row.receipt, receipt["error"] != nil { return .notDelivered }
            return row.awaitsReply ? .failed : (accepted(row, read: read) ? .delivered : .waiting)
        case "waiting":
            // Still with the lane (queued, running, a peer's task at work): the lane itself brings the answer. Handed into a live session and done there (Claude): an answer is owed only if one was asked for.
            guard AgentConversationSession.liveHandOff(row), !row.awaitsReply else { return .waiting }
            return accepted(row, read: read) ? .delivered : .waiting
        default: return accepted(row, read: read) ? (read ? .read : .delivered) : .waiting
        }
    }

    public struct InboxDoor: Sendable {
        public let agent: String
        public let handle: String
        public let inbox: URL
        public let tool: String
        public let options: Set<String>
        public let tap: String?
        public var liveReader: Bool { tap != nil }
        public func remedy() -> JSONValue {
            Repair.remedy(owner: "\(handle) inbox reader", nextCall: nil, tap: tap)
        }
    }

    private static let inboxRecipes: [String: (path: String, tool: String, options: Set<String>, tap: String?)] = [
        "claude": ("claude-bridge/claude-inbox.jsonl", "claude_message", ["pair_reviewer"], "Claude Code → open a Claude Code session, which reads its inbox"),
        "codex": ("codex-nativeagent-bridge/codex-inbox.jsonl", "codex_message", ["model", "reasoning_effort", "fast", "pair_reviewer", "completion_mode", "repository"], nil),
        "omp": ("omp-bridge/omp-inbox.jsonl", "omp_message", ["timeout_seconds"], nil),
    ]
    private static let commonInboxOptions: Set<String> = ["working_directory", "topic", "priority", "desk_item"]
    public static let inboxOptionKeys = inboxRecipes.values.reduce(into: commonInboxOptions) { $0.formUnion($1.options) }

    /// A live reader, rather than a launched run, owns acceptance for this door.
    public static func claudeInbox(_ row: AgentConversationRecord) -> Bool {
        guard case .object(let receipt)? = row.receipt, case .string(let path)? = receipt["filePath"] else { return false }
        return inboxRecipes.values.contains { $0.tap != nil && path.hasSuffix("/" + $0.path) }
    }

    /// A built-in lane's inbox, where the recipient marks a message read.
    public static func inbox(agent: String, bridgeConfigRoot root: URL) -> URL? {
        inboxRecipes[agent].map { root.appendingPathComponent($0.path) }
    }

    /// Only a saved who can carry an inbox door. A directory or installed program alone never establishes a recipient.
    public static func lane(for agent: String, dataRoot: URL, bridgeConfigRoot: URL? = nil) -> String? {
        door(for: agent, dataRoot: dataRoot, bridgeConfigRoot: bridgeConfigRoot)?.handle
    }

    /// A live inbox reader or a host's inbound bridge can answer during a send, as can command sessions and remote request/reply transports.
    package static func answersLive(agent: String, peer: AgentPeerContact?, dataRoot: URL) -> Bool {
        guard let peer, peer.ability == nil else { return false }
        if let door = door(for: agent, dataRoot: dataRoot) { return door.liveReader }
        switch peer.transport {
        case .acp, .nativeAgent, .a2a, .desktopChat: return true
        case .mcpHost: return !ChatGPTDotIPCTransport.owns(peer)
        default: return false
        }
    }

    public static func door(for agent: String, dataRoot: URL, bridgeConfigRoot: URL? = nil, peers: [AgentPeerContact]? = nil) -> InboxDoor? {
        let peers = peers ?? (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        guard let peer = peers.first(where: { "peer:" + $0.id == agent || ($0.handles ?? []).contains(agent) }) else { return nil }
        // An explicitly addressed associated door keeps its own recipe.
        guard !peers.contains(where: { $0.id == peer.who }) else { return nil }
        let root = bridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let handles = (peer.handles ?? []).filter { agent.hasPrefix("peer:") || $0 == agent }
        for handle in handles {
            guard let recipe = inboxRecipes[handle], peers.filter({ ($0.handles ?? []).contains(handle) }).count == 1 else { continue }
            let inbox = root.appendingPathComponent(recipe.path)
            guard FileManager.default.fileExists(atPath: inbox.path) else { continue }
            return InboxDoor(agent: "peer:" + peer.id, handle: handle, inbox: inbox, tool: recipe.tool,
                options: recipe.options.union(commonInboxOptions), tap: recipe.tap)
        }
        return nil
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
            || AgentConversationView.codingReply(value).text != nil
    }

}

public enum AgentConversationContext {
    /// Suppresses only the conversational facade for an owner recovery read, or for a queued send resumed after a restart (the facade already owns that send). The complete original tool permission chain still executes.
    @TaskLocal public static var isInternalRead = false
}
