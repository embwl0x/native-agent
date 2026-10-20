import AgentWorkspace
import Desk
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
}

public enum HumanConversationReader {
    public static func string(_ value: JSONValue?) -> String? { HumanConversationIndex.string(value) }
    public static func object(_ value: JSONValue?) -> [String: JSONValue] { HumanConversationIndex.object(value) }
    public static func rows(dataRoot: URL) throws -> [[String: JSONValue]] { try HumanConversationIndex.rows(dataRoot: dataRoot) }
    public static func read(sessionID: String, dataRoot: URL, replyBefore: Date? = nil) async throws -> HumanConversationSnapshot {
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
            forSessionId: sessionID, limit: replyBefore == nil ? 128 : nil, strictEvidence: true)
        let complete = !["missing", "read_failed", "invalid_encoding", "invalid_session_id"].contains(result.stats.mode)
            && result.stats.malformedRowCount == 0 && result.stats.invalidShapeRowCount == 0
        let recent = result.messages.suffix(128)
        let visible = recent.filter { ["user", "assistant"].contains($0.role) }
        let lastID = result.messages.last.flatMap { string(object($0.extras)["id"]) }
        let human = result.messages.last { message in
            message.role == "user" && (replyBefore.map {
                (DeskClock.parseISO(message.timestamp) ?? .distantFuture) <= $0
            } ?? true)
        }
        var route: TurnEnvelope?
        if let human, complete, replyBefore == nil || result.messages.filter({ $0.role == "user" }).allSatisfy({
            DeskClock.parseISO($0.timestamp) != nil
        }) {
            let metadata = object(object(human.extras)["metadata"])
            let candidate = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
            // Never infer User from a bridge/worker turn or decode a destination from a session id.
            if metadata["mechanicalKind"] == nil, object(metadata["origin"]).isEmpty,
               let candidate, candidate.agent == nil,
               ["app", "chat", "mac", "telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(candidate.surface) {
                route = candidate
            }
        }
        let generation = ChatSessionIndexFile.transcriptGeneration(in: row).map(String.init) ?? "legacy"
        return .init(sessionID: sessionID, title: string(row["title"]) ?? "Conversation",
                     source: string(row["source"]) ?? "app", revision: generation + ":" + (lastID ?? "unavailable"), sourceRevision: generation,
                     lastMessageID: lastID, route: route, messages: visible, complete: complete)
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
        // Each message shown is read under its own row's stamp (a bridge turn's
        // door, every peer that steered it) through the one per-line path.
        var untrusted = false
        let messages = snapshot.messages.suffix(limit).map { message -> JSONValue in
            let row = object(message.extras)
            var value: [String: JSONValue] = ["role": .string(message.role), "text": .string(String(message.content.prefix(6000))),
                "timestamp": .string(message.timestamp), "message_id": row["id"] ?? .null,
                "truncated": .bool(message.content.count > 6000)]
            let metadata = object(row["metadata"])
            let bridged = message.role == "user" && (string(object(metadata["origin"])["surface"])?.hasSuffix("-bridge") == true
                || TurnEnvelope.fromPersistedMetadata(metadata["envelope"])?.surface.hasSuffix("-bridge") == true)
            let stamp = ContactThread.stamp(id: string(row["id"]) ?? "", metadata: metadata)
            let speakers = ContactThread.consume(mine: !bridged, source: stamp.source, steeredBy: stamp.steeredBy, text: message.content) {
                PeerDataTaint.markConsumed(peer: $0, line: $1)
            }
            if !speakers.isEmpty {
                let principals = speakers.map { PeerTrust.principal($0, dataRoot: dataRoot) }
                if bridged { value["agent_id"] = .string(principals[0]) }
                let trusted = principals.allSatisfy { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) }
                value["untrusted_remote_data"] = .bool(!trusted)
                untrusted = untrusted || !trusted
            }
            return .object(value)
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
        if untrusted { result["untrusted_remote_data"] = .bool(true) }
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
