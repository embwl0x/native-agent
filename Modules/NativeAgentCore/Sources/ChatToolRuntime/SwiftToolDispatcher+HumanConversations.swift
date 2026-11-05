import AgentWorkspace
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import Transcripts
import ChatTurnContracts
// Blueprint: | `SwiftToolDispatcher+HumanConversations.swift` | Index/transcript-owned routes; bounded remote provenance reads |

/// A read model over the existing index and transcript, never another session store.
public struct HumanConversationSnapshot: Sendable {
    public let sessionID: String
    public let title: String
    public let source: String?
    public let revision: String?
    public let sourceRevision: String?
    public let lastMessageID: String?
    public let route: TurnEnvelope?
    public let messages: [ChatMessage]
    public let complete: Bool
}

public enum HumanConversationReader {
    public static func rows(dataRoot: URL) throws -> [[String: JSONValue]] { try HumanConversationIndex.rows(dataRoot: dataRoot) }
    public static func read(sessionID: String, dataRoot: URL, surface: String? = nil) async throws -> HumanConversationSnapshot {
        try await readSnapshot(sessionID: sessionID, dataRoot: dataRoot, surface: surface)
    }

    /// A queued peer/mechanical row does not replace the person's session destination. Explicit replies keep their stricter latest-user-row rule through
    /// `read`.
    public static func readForSessionDelivery(sessionID: String, dataRoot: URL) async throws -> ChatToolSessionContext.ReplyRoute? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil,
              let row = try rows(dataRoot: dataRoot).first(where: { $0["id"]?.stringValue == sessionID }),
              let source = row["source"]?.stringValue else { return nil }
        // The index owns local presentation; transcript size is irrelevant. Its row records a source; a route names the surface it arrived on.
        let surface = ChatThreadKind.surface(transcriptSource: source)
        if surface == "chat" { return .init(surface: surface) }
        // Only remote destinations need historical provenance. One bounded backward read never interprets an exhausted window as a destination.
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        guard let tail = try SwiftNativePersistenceCore.tailPhysicalLines(path, limit: 2048, maxBytes: 1024 * 1024) else { return nil }
        for data in tail.lines.dropFirst(tail.leadingFragment ? 1 : 0).reversed() {
            guard case .object(let fields) = try JSONValue.parse(data),
                  let role = fields["role"]?.stringValue else { return nil }
            guard role == "user" else { continue }
            let metadata = fields["metadata"]?.objectValue ?? [:]
            let envelope = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
            if metadata["mechanicalKind"] != nil || !(metadata["origin"]?.objectValue ?? [:]).isEmpty
                || envelope?.agent != nil || envelope?.surface.hasSuffix("-bridge") == true { continue }
            guard routeAvailable(envelope) else { return nil }
            return envelope?.replyRoute
        }
        return nil
    }

    private static func readSnapshot(sessionID: String, dataRoot: URL, surface: String?) async throws -> HumanConversationSnapshot {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil,
              let row = try rows(dataRoot: dataRoot).first(where: { $0["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) == sessionID }) else {
            throw AutonomyGateError.toolDenied(reason: "This conversation is unavailable. Open the conversation list again.")
        }
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        let size = try transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else {
            throw AutonomyGateError.toolDenied(
                reason: "This conversation is too large for an exact recent read. Search its history for a specific message instead.")
        }
        let result = try await SessionHistoryReader(dataRoot: dataRoot).messagesWithStats(
            forSessionId: sessionID, limit: 128, strictEvidence: true)
        let complete = !["missing", "read_failed", "invalid_encoding", "invalid_session_id"].contains(result.stats.mode)
            && result.stats.malformedRowCount == 0 && result.stats.invalidShapeRowCount == 0
        let recent = result.messages.suffix(128)
        let visible = recent.filter { ["user", "assistant"].contains($0.role) }
        let lastID = result.messages.last.flatMap { ($0.extras?.objectValue ?? [:])["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) }
        // With `surface`, the thread's latest message from that surface (one thread, many doors).
        let human = result.messages.last { message in
            guard message.role == "user" else { return false }
            // An unmarked row with missing/invalid routing remains the latest candidate and makes the route unavailable; absence is not a reason to skip it.
            return surface.map { wanted in
                TurnEnvelope.fromPersistedMetadata(((message.extras?.objectValue ?? [:])["metadata"]?.objectValue ?? [:])["envelope"])?.surface == wanted
            } ?? true
        }
        var route: TurnEnvelope?
        if let human, complete {
            let metadata = ((human.extras?.objectValue ?? [:])["metadata"]?.objectValue ?? [:])
            let candidate = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
            // Never infer the person from peer/worker turns or decode a destination from a session id.
            if metadata["mechanicalKind"] == nil, (metadata["origin"]?.objectValue ?? [:]).isEmpty,
               let candidate, candidate.agent == nil,
               ["chat", "telegram", "slack", "ios"].contains(candidate.surface) {
                route = candidate
            }
        }
        let generation = ChatSessionIndexFile.transcriptGeneration(in: row).map(String.init)
        return .init(sessionID: sessionID, title: row["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "Conversation",
                     source: row["source"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), revision: generation.flatMap { generation in lastID
                         .map { generation + ":" + $0 } }, sourceRevision: generation,
                     lastMessageID: lastID, route: route, messages: visible, complete: complete)
    }
    /// Expose reply eligibility with the bounded conversation read so callers need no second routing store.
    public static func open(turn: Turn, sessionID id: String, limit: Int?, dataRoot: URL) async -> JSONValue {
        let limit = min(16, max(1, limit ?? 8))
        let snapshot: HumanConversationSnapshot
        do { snapshot = try await read(sessionID: id, dataRoot: dataRoot) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        let current = turn.verifiedSessionID == id
        let canReply = !current && snapshot.lastMessageID != nil && routeAvailable(snapshot.route)
        var untrusted = false
        let rows = snapshot.messages.suffix(limit).map {
            ContactThread.Line(($0.extras?.objectValue ?? [:]), role: $0.role, text: $0.content, timestamp: $0.timestamp)
        }
        let messages = ContactThread.project(rows).map { line -> JSONValue in
            var value: [String: JSONValue] = ["role": .string(line.role), "text": .string(String(line.text.prefix(6000))),
                "timestamp": line.timestamp.map(JSONValue.string) ?? .null, "message_id": line.id.isEmpty ? .null : .string(line.id),
                "stamp": line.stamp.json,
                "truncated": .bool(line.text.count > 6000)]
            if let speaker = line.speakers.first {
                let principal = PeerTrust.principal(speaker, dataRoot: dataRoot)
                let trusted = PeerTrust.ownerTrusts(principal, dataRoot: dataRoot)
                let bridged = line.role == "user" && ((line.metadata["origin"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty
                    ? nil : $0 })?.hasSuffix("-bridge") == true
                    || TurnEnvelope.fromPersistedMetadata(line.metadata["envelope"])?.surface.hasSuffix("-bridge") == true)
                if bridged { value["agent_id"] = .string(principal) }
                value["untrusted_remote_data"] = .bool(!trusted)
                untrusted = untrusted || !trusted
            }
            return .object(value)
        }
        var result: [String: JSONValue] = ["status": .string(snapshot.complete ? "ok" : "unavailable"),
            "conversation_session_id": .string(id), "title": .string(snapshot.title),
            "surface": snapshot.source.map { JSONValue.string(ChatThreadKind.surface(transcriptSource: $0)) } ?? .null,
            "revision": snapshot.revision.map(JSONValue.string) ?? .null,
            "source_revision": snapshot.sourceRevision.map(JSONValue.string) ?? .null,
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
        case "chat": return true
        case "telegram":
            guard let destination = route.destinationId, Int(destination) != nil else { return false }
            return route.threadId == nil || Int(route.threadId!) != nil
        case "slack": return route.destinationId?.isEmpty == false
        case "ios":
            return route.sourceKey == "iphone" || (route.sourceKey?.hasPrefix("iphone:") == true && (route.sourceKey?.count ?? 0) > 7)
        default: return false
        }
    }
}
