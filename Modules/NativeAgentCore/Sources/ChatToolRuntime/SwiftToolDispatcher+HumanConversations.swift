import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts

/// A read model over the existing index and transcript, never another session store.
public struct HumanConversationSnapshot: Sendable {
    public let sessionID: String
    public let title: String
    public let source: String
    public let revision: String
    public let sourceRevision: String
    public let lastMessageID: String?
    public let route: TurnEnvelope?
    public let messages: [ChatMessage]
    public let complete: Bool
    /// "peer:<id>" when an untrusted bridge peer wrote its user rows.
    public var peerOrigin: String? = nil
}

public enum HumanConversationReader {
    public static func string(_ value: JSONValue?) -> String? { HumanConversationIndex.string(value) }
    public static func object(_ value: JSONValue?) -> [String: JSONValue] { HumanConversationIndex.object(value) }
    public static func rows(dataRoot: URL) throws -> [[String: JSONValue]] { try HumanConversationIndex.rows(dataRoot: dataRoot) }
    public static func read(sessionID: String, dataRoot: URL) async throws -> HumanConversationSnapshot {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil,
              let row = try rows(dataRoot: dataRoot).first(where: { string($0["id"]) == sessionID }) else {
            throw AutonomyGateError.toolDenied(reason: "This conversation is unavailable. Open the conversation list again.")
        }
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        let size = try transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else {
            throw AutonomyGateError.toolDenied(reason: "This conversation is too large for an exact recent read. Search its history for a specific message instead.")
        }
        let result = try await SessionHistoryReader(dataRoot: dataRoot).messagesWithStats(
            forSessionId: sessionID, limit: 128, strictEvidence: true)
        let complete = !["missing", "read_failed", "invalid_encoding", "invalid_session_id"].contains(result.stats.mode)
            && result.stats.malformedRowCount == 0 && result.stats.invalidShapeRowCount == 0
        let visible = result.messages.filter { ["user", "assistant"].contains($0.role) }
        let lastID = result.messages.last.flatMap { string(object($0.extras)["id"]) }
        let human = result.messages.last(where: { $0.role == "user" })
        var route: TurnEnvelope?
        if let human, complete {
            let metadata = object(object(human.extras)["metadata"])
            let candidate = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
            // Never infer User from a bridge/worker turn or decode a destination from a session id.
            if metadata["mechanicalKind"] == nil, object(metadata["origin"]).isEmpty,
               let candidate, candidate.agent == nil,
               ["app", "chat", "mac", "telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(candidate.surface) {
                route = candidate
            }
        }
        // 2026-09-22: a peer-opened session's words are peer data; label them so the taint latches.
        let peerOrigin = result.messages.lazy.filter { $0.role == "user" }.compactMap { message -> String? in
            let metadata = object(object(message.extras)["metadata"])
            let origin = object(metadata["origin"])
            let envelope = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
            guard (string(origin["surface"]) ?? envelope?.surface)?.hasSuffix("-bridge") == true else { return nil }
            let agent = string(origin["agent"]) ?? envelope?.agent
            let peer: String
            if let id = envelope?.verifiedUserId, !id.isEmpty {
                peer = id.hasPrefix("peer:") ? id : "peer:" + id
            } else if let agent, ["claude", "codex", "omp"].contains(agent) {
                peer = agent
            } else {
                peer = "peer:unknown"
            }
            return PeerTrust.ownerTrusts(peer, dataRoot: dataRoot) ? nil : peer
        }.first
        let generation = ChatSessionIndexFile.transcriptGeneration(in: row).map(String.init) ?? "legacy"
        return .init(sessionID: sessionID, title: string(row["title"]) ?? "Conversation",
                     source: string(row["source"]) ?? "app", revision: generation + ":" + (lastID ?? "unavailable"), sourceRevision: generation,
                     lastMessageID: lastID, route: route, messages: visible, complete: complete, peerOrigin: peerOrigin)
    }
    /// One conversation's latest messages (8, up to 16) and whether
    /// chat_reply can answer it: the app door's chat item read, which the
    /// workspace opens too.
    public static func open(sessionID id: String, limit: Int?, dataRoot: URL) async -> JSONValue {
        let limit = min(16, max(1, limit ?? 8))
        let snapshot: HumanConversationSnapshot
        do { snapshot = try await read(sessionID: id, dataRoot: dataRoot) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        let current = ChatToolSessionContext.verifiedSessionId == id
        let canReply = !current && snapshot.lastMessageID != nil && routeAvailable(snapshot.route)
        let messages = snapshot.messages.suffix(limit).map { message -> JSONValue in
            let row = object(message.extras)
            return .object(["role": .string(message.role), "text": .string(String(message.content.prefix(6000))),
                "timestamp": .string(message.timestamp), "message_id": row["id"] ?? .null,
                "truncated": .bool(message.content.count > 6000)])
        }
        var result: [String: JSONValue] = ["status": .string(snapshot.complete ? "ok" : "unavailable"),
            "conversation_session_id": .string(id), "title": .string(snapshot.title),
            "surface": .string(snapshot.source), "revision": .string(snapshot.revision),
            "source_revision": .string(snapshot.sourceRevision),
            "last_message_id": snapshot.lastMessageID.map(JSONValue.string) ?? .null,
            "reply_available": .bool(canReply),
            "reply_kind": .string(current ? "current_turn" : (canReply ? "saved_route" : "unavailable")),
            "messages": .array(messages), "coverage": .string(snapshot.complete ? "recent_transcript" : "incomplete_transcript"),
            "note": .string(current ? "This is your active conversation. Answer normally here; no extra send is needed."
                : canReply ? "Reply returns to the exact human conversation and its recorded destination."
                : "History is available, but a current exact reply route is not proven. Nothing was sent.")]
        if let peer = snapshot.peerOrigin {
            result["untrusted_remote_data"] = .bool(true)
            result["agent"] = .string(peer)
        }
        return .object(result)
    }
    public static func routeAvailable(_ envelope: TurnEnvelope?) -> Bool {
        guard let envelope else { return false }
        let route = envelope.replyRoute
        switch envelope.surface {
        case "app", "chat", "mac": return true
        case "telegram":
            guard let destination = route.destinationId, Int(destination) != nil else { return false }
            return route.threadId == nil || Int(route.threadId!) != nil
        case "slack": return route.destinationId?.isEmpty == false
        case "ios", "iphone", "mobile", "icloud":
            return route.sourceKey == "iphone" || (route.sourceKey?.hasPrefix("iphone:") == true && (route.sourceKey?.count ?? 0) > 7)
        default: return false
        }
    }
}
