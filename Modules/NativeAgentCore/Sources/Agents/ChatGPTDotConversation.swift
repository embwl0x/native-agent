import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore

/// Dot's room is an ingress into his ordinary contact session, not an outbound reply tracker.
actor ChatGPTDotConversation {
    let dataRoot: URL
    let clients: any AgentContactClients
    private var pull: Task<JSONValue, Error>?
    private var pendingMessages: [JSONValue] = []
    private struct Admission: Codable {
        let message: JSONValue
        var started = false
    }
    private var admissionTasks: Set<String> = []

    init(dataRoot: URL, clients: any AgentContactClients) {
        self.dataRoot = dataRoot
        self.clients = clients
    }

    func resumeAdmissions() async throws {
        for peer in try AgentPeerStore(dataRoot: dataRoot).list() where ChatGPTDotIPCTransport.owns(peer) {
            if try admissions(peer: peer.id).values.contains(where: { !$0.started }) {
                _ = try await append([], peer: peer)
            }
        }
    }

    private func admissionFile(peer: String) -> URL {
        dataRoot.appendingPathComponent("agent-conversations/dot-admission-\(peer).json")
    }

    private func admissions(peer: String) throws -> [String: Admission] {
        let file = admissionFile(peer: peer)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: Admission].self, from: Data(contentsOf: file))
    }

    private func saveAdmission(_ admission: Admission?, id: String, peer: String) throws {
        var saved = try admissions(peer: peer)
        saved[id] = admission
        let file = admissionFile(peer: peer)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(saved), to: file)
    }

    private func startAdmission(id: String, peer: String) throws {
        guard var saved = try admissions(peer: peer)[id], !saved.started else {
            throw AgentConversationStore.Failure(message: "Dot's reply has already started admission.")
        }
        saved.started = true
        try saveAdmission(saved, id: id, peer: peer)
    }

    func refresh(sessionID: String) async throws -> Bool {
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: {
            ChatGPTDotIPCTransport.owns($0) && principal($0).storedConversation("mcp-" + $0.id) == sessionID
        }) else { return false }
        let tools = clients.bridgeToolDispatchClient(fileAccess: "read_only", verifiedSessionId: sessionID)
        _ = try await tools.dispatch(tool: "agent_read", input: ["agent": .string("peer:" + peer.id)], surface: "chat")
        return true
    }

    func conversation(root: URL, peer: AgentPeerContact, messages: [JSONValue], sent: String?) async throws -> JSONValue {
        guard root.standardizedFileURL == dataRoot.standardizedFileURL else {
            throw AgentConversationStore.Failure(message: "Dot's conversation belongs to another app data root.")
        }
        if let sent {
            let session = principal(peer).storedConversation("mcp-" + peer.id)
            var clientID: String?
            if case .object(let receipt)? = messages.first, case .string(let id)? = receipt["client_user_message_id"] {
                clientID = id
            }
            // The person's own send from his thread is marked theirs, not hers.
            let byPerson = PersonInitiatedSend.current?.matches(["agent": .string("peer:" + peer.id), "text": .string(sent)]) == true
            try await clients.bridgeChatClient().appendAgentConversationSend(sessionID: session, text: sent,
                                                                             clientUserMessageID: clientID, byPerson: byPerson)
            return .object(["status": .string("sent"), "sent": .bool(true)])
        }
        var pendingIDs = Set(pendingMessages.compactMap { message -> String? in
            guard case .object(let fields) = message, case .string(let id)? = fields["id"] else { return nil }
            return id
        })
        for message in messages {
            guard case .object(let fields) = message, case .string(let id)? = fields["id"],
                  case .string? = fields["text"], case .string(let at)? = fields["at"],
                  roomDate(at) != nil else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            if pendingIDs.insert(id).inserted { pendingMessages.append(message) }
        }
        if let pull { return try await pull.value }
        let task = Task { try await self.drain(peer: peer) }
        pull = task
        return try await task.value
    }

    private func drain(peer: AgentPeerContact) async throws -> JSONValue {
        defer { pull = nil }
        var result: JSONValue
        repeat {
            let messages = pendingMessages
            pendingMessages.removeAll()
            result = try await append(messages, peer: peer)
        } while !pendingMessages.isEmpty
        return result
    }

    private func principal(_ peer: AgentPeerContact) -> AgentBridgePrincipal {
        .init(id: peer.id, peerID: peer.id, elevated: peer.elevationAllowed, displayName: peer.name)
    }

    private func append(_ messages: [JSONValue], peer: AgentPeerContact) async throws -> JSONValue {
        // Recheck the saved contact and Trust at ingestion, after the read-only IPC pull.
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peer.id }),
              ChatGPTDotIPCTransport.owns(peer) else {
            throw AgentConversationStore.Failure(message: "Dot's contact is no longer connected.")
        }
        let principal = principal(peer), context = "mcp-" + peer.id
        let session = principal.storedConversation(context)
        let persistence = SwiftNativePersistenceCore()
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
        let seenFile = dataRoot.appendingPathComponent("agent-conversations/dot-seen-\(peer.id).json")
        let seen: [String]
        if FileManager.default.fileExists(atPath: seenFile.path) {
            seen = try JSONDecoder().decode([String].self, from: Data(contentsOf: seenFile))
        } else { seen = [] }
        var rows = try await persistence.readJSONL(transcript)
        // Durable reply IDs supersede the temporary seen list.
        var durableIDs = Set(rows.compactMap(Self.replyID))
        let replies = try replies(messages, rows: rows)
        let cleanupFile = dataRoot.appendingPathComponent("agent-conversations/dot-reply-cleanup-\(peer.id).json")
        if !FileManager.default.fileExists(atPath: cleanupFile.path) {
            let erroneous = Set(messages.compactMap { message -> String? in
                guard case .object(let fields) = message, fields["kind"] == .string("user"),
                      case .string(let id)? = fields["id"] else { return nil }
                return "dot-room:" + id
            })
            try await cleanup(transcript: transcript, seen: Set(seen), replies: replies, erroneous: erroneous, persistence: persistence)
            try await persistence.writeJSON(.bool(true), to: cleanupFile)
            rows = try await persistence.readJSONL(transcript)
            durableIDs = Set(rows.compactMap(Self.replyID))
        }
        let client = clients.bridgeChatClient()
        var appended = false
        let pending = try admissions(peer: peer.id)
        let recovered = try pending.values.filter { !$0.started }.map { admission -> (JSONValue, Date) in
            guard case .object(let fields) = admission.message, case .string(let at)? = fields["at"],
                  let date = roomDate(at) else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            return (admission.message, date)
        }.sorted { $0.1 < $1.1 }.map { $0.0 }
        var offered: Set<String> = []
        for message in recovered + replies {
            guard case .object(let fields) = message, case .string(let roomID)? = fields["id"],
                  case .string(let text)? = fields["text"] else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            let id = "dot-room:" + roomID
            let key = peer.id + ":" + id
            guard offered.insert(id).inserted, !admissionTasks.contains(key) else { continue }
            if pending[id]?.started == true { continue }
            if durableIDs.contains(id), pending[id] == nil { continue }
            // His reply is a message in her Dot session that wakes her, like any
            // contact's; she answers him with agent_message when she wants to.
            let turn = AgentContactTurn(taskID: UUID().uuidString, context: context, requestID: id, principal: principal,
                parts: [.text(text + "\n\n(Dot sees your answer only if you send it to him with agent_message.)")],
                bindRun: { _, _ in try await self.startAdmission(id: id, peer: peer.id) })
            let plain = turn.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            let request = AgentContactRuntime.inboundRequest(principal: principal, context: context, plain: plain,
                messageID: id, originID: id)
            if pending[id] == nil { try saveAdmission(Admission(message: message), id: id, peer: peer.id) }
            var enqueued: EnqueuedUserMessage?
            let savedRows = rows.filter { Self.replyID($0) == id }
            if !savedRows.isEmpty {
                guard savedRows.count == 1, case .object(let row) = savedRows[0],
                      case .string(let run)? = row["runId"] else {
                    throw AgentConversationStore.Failure(message: "Dot's saved reply has no unique enqueued turn.")
                }
                // Any non-user row proves this run already began, even if a
                // previous app revision did not retain an admission marker.
                if rows.contains(where: { value in
                    guard case .object(let other) = value else { return false }
                    return other["runId"] == .string(run) && other["role"] != .string("user")
                }) {
                    try startAdmission(id: id, peer: peer.id)
                    continue
                }
                enqueued = .init(sessionId: session, runId: run)
            }
            admissionTasks.insert(key)
            let accepted: EnqueuedUserMessage
            do {
                if let enqueued { accepted = enqueued }
                else { accepted = try await request.enqueue(on: client) }
            } catch { admissionTasks.remove(key); throw error }
            durableIDs.insert(id)
            let root = dataRoot
            Task {
                defer { admissionTasks.remove(key) }
                // Keep this exact turn and saved row pending until admitted.
                // Only admission refusal is safe to retry: nothing ran yet.
                while !Task.isCancelled {
                    do {
                        _ = try await AgentContactRuntime.run(turn, client: client, dataRoot: root,
                                                             enqueued: accepted, emit: { _ in })
                        try saveAdmission(nil, id: id, peer: peer.id)
                        return
                    } catch is TurnAdmission.Full {
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    } catch { return }
                }
            }
            appended = true
        }
        if !seen.isEmpty {
            try await persistence.writeJSON(.array([]), to: seenFile)
        }
        if appended {
            AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, inbound: true)
        }
        rows = try await persistence.tailJSONL(transcript, limit: 100, maxBytes: 1_048_576)
        if !peer.elevationAllowed { PeerDataTaint.markConsumed(peer: "peer:" + peer.id) }
        return .object(["status": .string("ready"), "agent": .string(peer.name), "agent_id": .string("peer:" + peer.id),
                        "conversation_id": .string(session), "untrusted_remote_data": .bool(true),
                        "conversation": .array(rows.compactMap { value -> JSONValue? in
                            guard case .object(let row) = value, let text = row["content"],
                                  row["role"] == .string("user") || row["role"] == .string("assistant") else { return nil }
                            return .object(["id": row["id"] ?? .null, "at": row["createdAt"] ?? .null,
                                            "from": .string(Self.author(of: row, peer: peer)), "text": text])
                        })])
    }

    private static func replyID(_ value: JSONValue) -> String? {
        guard case .object(let row) = value, row["role"] == .string("user"),
              case .object(let metadata)? = row["metadata"], case .object(let origin)? = metadata["origin"],
              case .string(let id)? = origin["replyTo"], id.hasPrefix("dot-room:") else { return nil }
        return id
    }

    /// Who wrote a row of Dot's session. The person talks to her here on
    /// purpose, so a user row is Dot's only when it came over his bridge (it
    /// carries his origin stamp); the rest are the person's own words.
    private static func author(of row: [String: JSONValue], peer: AgentPeerContact) -> String {
        if case .object(let metadata)? = row["metadata"], metadata["byPerson"] == .bool(true) { return "the person" }
        guard row["role"] == .string("user") else { return "Agent" }
        guard case .object(let metadata)? = row["metadata"] else { return "the person" }
        if metadata["origin"] != nil { return peer.name }
        if case .object(let envelope)? = metadata["envelope"],
           envelope["surface"] == .string("agent-bridge") || envelope["userId"] == .string(peer.id) {
            return peer.name
        }
        return "the person"
    }

    private func roomDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func replies(_ messages: [JSONValue], rows: [JSONValue]) throws -> [JSONValue] {
        var sentIDs = Set<String>(), legacySends = Set<String>()
        for row in rows {
            guard case .object(let row) = row, row["role"] == .string("assistant"),
                  row["source"] == .string("agent-bridge"), case .string(let text)? = row["content"] else { continue }
            if case .object(let metadata)? = row["metadata"], case .string(let id)? = metadata["dotClientUserMessageID"] {
                sentIDs.insert(id)
            } else {
                // Sends made before this fix recorded their text, but not their room client ID.
                legacySends.insert(text)
            }
        }
        let timeline = try messages.map { message -> (JSONValue, [String: JSONValue], Date) in
            guard case .object(let fields) = message, case .string(let at)? = fields["at"],
                  let date = roomDate(at) else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            return (message, fields, date)
        }.sorted { $0.2 < $1.2 }
        var afterSend: Date?
        var replies: [JSONValue] = []
        for (message, fields, date) in timeline {
            if fields["kind"] == .string("user") {
                let ownSend: Bool
                if case .string(let id)? = fields["client_id"], sentIDs.contains(id) {
                    ownSend = true
                } else if case .string(let text)? = fields["text"] {
                    ownSend = legacySends.contains(text)
                } else { ownSend = false }
                afterSend = ownSend ? date : nil
            } else if fields["kind"] == .string("dot") {
                // His answer to her ask, or anything he addresses to her ("Agent, …") at any time.
                let text = (fields["text"].flatMap { if case .string(let t) = $0 { return t }; return nil } ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let addressed = text.hasPrefix("agent") || text.hasPrefix("@agent")
                if addressed || afterSend.map({ date > $0 }) == true { replies.append(message) }
            }
        }
        return replies
    }

    private func cleanup(transcript: URL, seen: Set<String>, replies: [JSONValue], erroneous: Set<String>,
                         persistence: SwiftNativePersistenceCore) async throws {
        let timestamps = Dictionary(uniqueKeysWithValues: replies.compactMap { message -> (String, String)? in
            guard case .object(let fields) = message, case .string(let id)? = fields["id"],
                  case .string(let at)? = fields["at"] else { return nil }
            return ("dot-room:" + id, at)
        })
        guard FileManager.default.fileExists(atPath: transcript.path) else { return }
        let changed = try await persistence.withFileLock(transcript) {
            let text = try String(contentsOf: transcript, encoding: .utf8)
            var output = "", changed = false
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let ending = index < lines.count - 1 ? "\n" : ""
                guard !line.isEmpty, case .object(var row) = try JSONValue.parse(Data(line.utf8)),
                      row["role"] == .string("user"), case .object(let metadata)? = row["metadata"],
                      case .object(let origin)? = metadata["origin"], origin["surface"] == .string("agent-bridge"),
                      case .string(let id)? = origin["replyTo"], id.hasPrefix("dot-room:"), seen.contains(id) else {
                    output += line + ending
                    continue
                }
                if erroneous.contains(id) { changed = true; continue }
                guard let at = timestamps[id] else { output += line + ending; continue }
                if row["createdAt"] != .string(at) {
                    row["createdAt"] = .string(at)
                    output += try JSONValue.object(row).serialize(pretty: false) + ending
                    changed = true
                } else { output += line + ending }
            }
            if changed { try await persistence.writeDataAtomicDurable(Data(output.utf8), to: transcript) }
            return changed
        }
        if changed { NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: transcript.deletingPathExtension().lastPathComponent) }
    }
}
