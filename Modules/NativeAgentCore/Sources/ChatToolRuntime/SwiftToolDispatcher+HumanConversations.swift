import AgentWorkspace
import AgentConversations
import ChatSessionWork
import CryptoKit
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
    public let latestUserMessageID: String?
    public let route: TurnEnvelope?
    public let messages: [ChatMessage]
    /// The full bounded snapshot's completeness, retained for the saved-reply guards.
    public let complete: Bool
    /// Readable user/assistant rows after the newest gap; older damage cannot make an intact requested tail partial.
    fileprivate let intactRecentMessages: Int
    public let unavailableFields: [String: String]
    public let recentRead: JSONValue
}

public enum HumanConversationReader {
    private static let recentRowLimit = 2048
    private static let recentByteLimit = 1024 * 1024
    private static let recentMessageLimit = 128

    public static func rows(dataRoot: URL) throws -> [[String: JSONValue]] { try HumanConversationIndex.rows(dataRoot: dataRoot) }
    @concurrent public static func read(sessionID: String, dataRoot: URL, surface: String? = nil) async throws -> HumanConversationSnapshot {
        try await readSnapshot(sessionID: sessionID, dataRoot: dataRoot, surface: surface)
    }

    /// A queued peer/mechanical row does not replace the person's session destination. Explicit replies keep their stricter latest-user-row rule through
    /// `read`.
    @concurrent public static func readForSessionDelivery(sessionID: String, dataRoot: URL) async throws -> ChatToolSessionContext.ReplyRoute? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil,
              let row = try rows(dataRoot: dataRoot).first(where: { $0["id"]?.stringValue == sessionID }),
              let source = row["source"]?.stringValue else { return nil }
        // The index owns local presentation; transcript size is irrelevant. Its row records a source; a route names the surface it arrived on.
        let surface = ChatThreadKind.surface(transcriptSource: source)
        if surface == "chat" { return .init(surface: surface) }
        // Only remote destinations need historical provenance. One bounded backward read never interprets an exhausted window as a destination.
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        guard let tail = try SwiftNativePersistenceCore.tailPhysicalLines(path, limit: recentRowLimit, maxBytes: recentByteLimit) else { return nil }
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

    /// The same person-index resolution admits an explicit reply and its advertised availability.
    private static func replyRow(sessionID: String, dataRoot: URL) throws -> [String: JSONValue]? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil else { return nil }
        return try rows(dataRoot: dataRoot).first { $0["id"]?.stringValue == sessionID }
    }

    @concurrent private static func readSnapshot(sessionID: String, dataRoot: URL, surface: String?) async throws -> HumanConversationSnapshot {
        guard let row = try replyRow(sessionID: sessionID, dataRoot: dataRoot) else {
            throw AutonomyGateError.toolDenied(reason: "This conversation is unavailable. Open the conversation list again.")
        }
        return try await readSnapshot(sessionID: sessionID, row: row, dataRoot: dataRoot, surface: surface)
    }

    @concurrent fileprivate static func readSnapshot(sessionID: String, row: [String: JSONValue], dataRoot: URL,
                                         surface: String?) async throws -> HumanConversationSnapshot {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let transcript = dataRoot.appendingPathComponent(row["messagesArchivePath"]?.stringValue ?? "chat/messages/\(sessionID).jsonl")
        let parent = transcript.resolvingSymlinksInPath().deletingLastPathComponent()
        guard ["chat/messages", "chat/archive/messages"].contains(where: {
            parent.path == dataRoot.appendingPathComponent($0).resolvingSymlinksInPath().path
        }) else { throw CocoaError(.fileReadNoPermission) }
        let tail = try SwiftNativePersistenceCore.tailPhysicalLines(transcript, limit: recentRowLimit, maxBytes: recentByteLimit)
        // Keep gaps in place: a damaged later row cannot certify an earlier row as the latest message or reply destination.
        var decoded: [ChatMessage?] = []
        var unreadable: [JSONValue] = []
        if let tail {
            for (index, data) in tail.lines.enumerated().dropFirst(tail.leadingFragment ? 1 : 0) {
                try Task.checkCancellation()
                let text = String(data: data, encoding: .utf8)
                if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let row = text.map { SessionHistoryReader.decodeRow($0) }
                decoded.append(row?.message)
                if row?.message == nil {
                    let fields = row?.value?.objectValue
                    let reason: String
                    if text == nil { reason = "invalid_utf8" }
                    else if let fields {
                        reason = ContactThread.Line(fields).provenanceFailure ?? "missing_message_id_role_or_content"
                    } else { reason = "invalid_json_object" }
                    unreadable.append(.object([
                        "physical_row_in_tail": .int(Int64(index + 1)),
                        "message_id": fields?["id"] ?? .null, "reason": .string(reason),
                        "sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())]))
                }
            }
        }
        let gaps = unreadable.count
        let intactRecentMessages = decoded.reversed().prefix { $0 != nil }.compactMap { $0 }
            .filter { ["user", "assistant"].contains($0.role) }.count
        let windowLimited = tail.map { $0.leadingFragment || $0.truncatedToByteWindow || $0.lines.count == recentRowLimit } ?? false
        let visible = Array(decoded.compactMap { $0 }.filter { ["user", "assistant"].contains($0.role) }.suffix(recentMessageLimit))
        let messagesLimited = visible.count < recentMessageLimit && windowLimited
        let complete = tail != nil && gaps == 0 && !messagesLimited
        func messageID(_ message: ChatMessage?) -> String? { message?.extras?.objectValue?["id"]?.stringValue }
        let lastID = messageID(decoded.last.flatMap { $0 })
        let missing = tail == nil ? "transcript_missing" : "not_in_recent_tail"
        var unavailable: [String: String] = [:]
        if tail == nil { unavailable["messages"] = missing }
        else if gaps > 0 { unavailable["messages"] = "unreadable_tail_rows" }
        else if messagesLimited { unavailable["messages"] = "recent_window_limit" }
        if lastID == nil { unavailable["last_message_id"] = decoded.isEmpty ? missing : "last_row_unreadable" }
        // With `surface`, the thread's latest user row from that surface (one thread, many doors).
        var latestUserID: String?
        var route: TurnEnvelope?
        var routeGap = missing
        for row in decoded.reversed() {
            guard let message = row else { routeGap = "later_row_unreadable"; break }
            guard message.role == "user" else { continue }
            let metadata = message.extras?.objectValue?["metadata"]?.objectValue ?? [:]
            let candidate = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
            if let surface, let candidate, candidate.surface != surface { continue }
            // A user row with unknown provenance could be from the requested surface; never skip it for an older destination.
            latestUserID = messageID(message)
            routeGap = "latest_user_route_unavailable"
            // Never infer the person from peer/worker turns or decode a destination from a session id.
            if metadata["mechanicalKind"] == nil, (metadata["origin"]?.objectValue ?? [:]).isEmpty,
               let candidate, candidate.agent == nil,
               ["chat", "telegram", "slack", "ios"].contains(candidate.surface), routeAvailable(candidate) {
                route = candidate
            }
            break
        }
        if latestUserID == nil { unavailable["latest_user_message_id"] = routeGap }
        if route == nil { unavailable["route"] = routeGap }
        let recentRead: JSONValue = .object([
            "byte_limit": .int(Int64(recentByteLimit)), "row_limit": .int(Int64(recentRowLimit)),
            "bytes_read": tail.map { JSONValue.int(Int64($0.bytesRead)) } ?? .null,
            "physical_rows_read": tail.map { JSONValue.int(Int64($0.lines.count)) } ?? .null,
            "leading_fragment_discarded": tail.map { JSONValue.bool($0.leadingFragment) } ?? .null,
            "unreadable_rows": tail == nil ? .null : .int(Int64(gaps)),
            "unreadable_row_details": tail == nil ? .null : .array(unreadable)])
        let generation = ChatSessionIndexFile.transcriptGeneration(in: row).map(String.init)
        return .init(sessionID: sessionID, title: row["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "Conversation",
                     source: row["source"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), revision: generation.flatMap { generation in lastID
                         .map { generation + ":" + $0 } }, sourceRevision: generation,
                     lastMessageID: lastID, latestUserMessageID: latestUserID, route: route, messages: visible, complete: complete,
                     intactRecentMessages: intactRecentMessages,
                     unavailableFields: unavailable, recentRead: recentRead)
    }
    /// Expose reply eligibility with the bounded conversation read so callers need no second routing store.
    @concurrent public static func open(turn: Turn, sessionID id: String, limit: Int?, dataRoot: URL) async -> JSONValue {
        let limit = min(recentMessageLimit, max(1, limit ?? 8))
        do {
            let snapshot = try await read(sessionID: id, dataRoot: dataRoot)
            return try open(turn: turn, snapshot: snapshot, limit: limit, dataRoot: dataRoot)
        } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }

    fileprivate static func open(turn: Turn, snapshot: HumanConversationSnapshot, limit: Int, dataRoot: URL) throws -> JSONValue {
        let id = snapshot.sessionID
        let current = turn.verifiedSessionID == id
        let replyResolvable = try replyRow(sessionID: id, dataRoot: dataRoot) != nil
        let canReply = replyResolvable && !current && snapshot.complete && snapshot.lastMessageID != nil && routeAvailable(snapshot.route)
        // Page coverage concerns the requested messages, not the reply resolver's larger intact-tail requirement.
        let complete = snapshot.complete || snapshot.intactRecentMessages >= limit
        var unavailable = snapshot.unavailableFields
        if complete { unavailable.removeValue(forKey: "messages") }
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
        var result: [String: JSONValue] = ["status": .string(complete ? "ok" : (snapshot.messages.isEmpty ? "unavailable" : "partial")),
            "conversation_session_id": .string(id), "title": .string(snapshot.title),
            "surface": snapshot.source.map { JSONValue.string(ChatThreadKind.surface(transcriptSource: $0)) } ?? .null,
            "revision": snapshot.revision.map(JSONValue.string) ?? .null,
            "source_revision": snapshot.sourceRevision.map(JSONValue.string) ?? .null,
            "last_message_id": snapshot.lastMessageID.map(JSONValue.string) ?? .null,
            "latest_user_message_id": snapshot.latestUserMessageID.map(JSONValue.string) ?? .null,
            "unavailable_fields": .object(unavailable.mapValues(JSONValue.string)),
            "recent_read": snapshot.recentRead,
            "reply_available": .bool(canReply),
            "reply_kind": .string(current ? "current_turn" : (canReply ? "saved_route" : "unavailable")),
            "messages": .array(messages), "coverage": .string(complete ? "recent_transcript" : "incomplete_transcript"),
            "note": .string(!complete && snapshot.messages.isEmpty
                ? "Recent history is unavailable; see unavailable_fields. Nothing was sent."
                : current ? "This is your active conversation. Answer normally here; no extra send is needed."
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

/// Reading a conversation is independent of whether its owner can route a reply to the person.
public enum ConversationReader {
    @concurrent public static func open(turn: Turn, id: String, limit: Int?, dataRoot: URL) async -> JSONValue {
        do {
            guard let owner = try AgentConversationStore(dataRoot: dataRoot).resolveConversation(id, scope: turn.verifiedSessionID) else {
                throw ToolFailureError("This conversation is not in the saved session or contact records. Read chat.list or agent.contacts again.",
                    effects: .none, code: "conversation_not_found")
            }
            switch owner {
            case .session(let row):
                guard let session = row["id"]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
                let snapshot = try await HumanConversationReader.readSnapshot(sessionID: session, row: row, dataRoot: dataRoot, surface: nil)
                return try HumanConversationReader.open(turn: turn, snapshot: snapshot, limit: min(128, max(1, limit ?? 8)), dataRoot: dataRoot)
            case .agent(let row):
                return AgentConversationView.view(row, details: false, read: true, dataRoot: dataRoot, historyLimit: limit ?? 8)
            }
        } catch { return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none) }
    }
}
