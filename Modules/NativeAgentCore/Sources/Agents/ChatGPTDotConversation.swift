import ChatTurnRuntime
import ChatTurnContracts
import AgentWorkspace
import AgentConversations
import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import Transcripts
// Blueprint: | `ChatGPTDotConversation.swift` | `ChatGPTDotConversation` actor; `refresh`, `conversation`; saved arrivals wait on `TurnAdmission` capacity signals; failed turns retain their actual cause and never create a second turn on link changes; launch resumes only arrivals whose turn has not started; the delegation runner stops subscriptions with discovery and Dot socket observation; old lifecycle callbacks cannot retry admissions |

/// Dot's room is an ingress into his ordinary contact session, not an outbound reply tracker.
actor ChatGPTDotConversation {
    let dataRoot: URL
    let clients: any AgentContactClients
    private var pull: Task<JSONValue, Error>?
    private var retired = false
    private var pendingMessages: [JSONValue] = []
    private struct Admission: Codable {
        var lifeID: String?
        let message: JSONValue
        var started = false
        /// The actual terminal reason and supplied provider cause, never replay authority.
        var failed: String?
        var retryCause: ProviderFailure?
    }
    private struct AdmissionWork { var task: Task<Void, Never>? }
    private var admissionTasks: [String: AdmissionWork] = [:]
    private var generation = UUID()
    private var recoveryAttempted = false

    init(dataRoot: URL, clients: any AgentContactClients) {
        self.dataRoot = dataRoot
        self.clients = clients
    }

    /// At launch. An interrupted admission has no proven network cause and stays terminal.
    func resumeAdmissions() async throws {
        guard !retired, !recoveryAttempted, !Task.isCancelled else { return }
        recoveryAttempted = true
        let generation = generation
        // Reserve this lifecycle before the recovery pass suspends.
        do {
            for peer in try AgentPeerStore(dataRoot: dataRoot).list() where ChatGPTDotIPCTransport.owns(peer) {
                for (id, admission) in try admissions(peer: peer.id)
                    where try admission.started && DataRootLife.isCurrent(admission.lifeID, in: dataRoot)
                        && admissionTasks[peer.id + ":" + id] == nil {
                    if admission.failed == nil {
                        try updateAdmissions(peer: peer.id) { $0[id] = Admission(lifeID: admission.lifeID,
                            message: admission.message, started: true, failed: "The app stopped before it finished.") }
                    }
                }
                if try admissions(peer: peer.id).values.contains(where: { !$0.started && $0.failed == nil }) {
                    _ = try await append([], peer: peer, recovery: generation)
                    guard self.generation == generation else { return }
                    try Task.checkCancellation()
                }
            }
        } catch {
            if self.generation == generation { retireSubscriptions() }
            throw error
        }
        guard self.generation == generation else { return }
        if Task.isCancelled { retireSubscriptions(); return }
    }

    func stopSubscriptions() async {
        retired = true
        let pull = pull
        let admissions = admissionTasks.values.compactMap(\.task)
        retireSubscriptions()
        pull?.cancel()
        for task in admissions { task.cancel() }
        _ = try? await pull?.value
        for task in admissions { await task.value }
    }

    private func retireSubscriptions() {
        recoveryAttempted = false
        generation = UUID()
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        self.generation == generation && recoveryAttempted && !retired
    }

    private func admissionFile(peer: String) -> URL {
        dataRoot.appendingPathComponent("agent-conversations/dot-admission-\(peer).json")
    }

    private func admissions(peer: String) throws -> [String: Admission] {
        let file = admissionFile(peer: peer)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return [:]
        }
        var saved = try JSONDecoder().decode([String: Admission].self, from: Data(contentsOf: file))
        for id in Array(saved.keys) where try !DataRootLife.isCurrent(saved[id]?.lifeID, in: dataRoot) {
            saved[id]?.started = true
            saved[id]?.failed = DataRootLife.stoppedReason
        }
        return saved
    }

    private func updateAdmissions(peer: String, _ mutate: (inout [String: Admission]) throws -> Void) throws {
        var saved = try admissions(peer: peer)
        try mutate(&saved)
        let file = admissionFile(peer: peer)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(saved), to: file)
    }

    private func startAdmission(id: String, peer: String) throws {
        try updateAdmissions(peer: peer) { saved in
            guard saved[id]?.started == false else { throw AgentConversationStore.Failure(message: "Dot's reply has already started admission.") }
            saved[id]?.started = true
        }
    }

    func refresh(sessionID: String) async throws -> Bool {
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: {
            ChatGPTDotIPCTransport.owns($0) && principal($0).storedConversation("mcp-" + $0.id) == sessionID
        }) else { return false }
        let tools = clients.bridgeToolDispatchClient(fileAccess: "read_only", verifiedSessionId: sessionID)
        _ = try await ChatToolSessionContext.$envelope.withValue(ChatToolSessionContext.envelope ?? .native("contact.refresh:" + peer.id)) {
            try await tools.dispatch(tool: "agent_read", input: ["agent": .string("peer:" + peer.id)], surface: "chat")
        }
        return true
    }

    func conversation(root: URL, peer: AgentPeerContact, messages: [JSONValue], sent: String?, window: [String: JSONValue]? = nil) async throws -> JSONValue {
        guard !retired else { throw CancellationError() }
        try Task.checkCancellation()
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
        if let window, case .string(let asked)? = window["conversation_id"] {
            let local = principal(peer).storedConversation("mcp-" + peer.id)
            let remote: JSONValue? = if case .object(let state) = ChatGPTDotIPCTransport.readiness { state["conversation_id"] } else { nil }
            guard asked == local || .string(asked) == remote else {
                return .object(["status": .string("unavailable"), "sent": .bool(false), "reason": .string("invalid_conversation"),
                    "detail": .string("Dot has one conversation; use the conversation_id returned by Dot's read or his current root. Omit it for a fresh read. Nothing was sent or read.")])
            }
        }
        for message in messages {
            guard case .object(let fields) = message, case .string? = fields["id"],
                  case .string? = fields["text"], case .string(let at)? = fields["at"],
                  roomDate(at) != nil else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            // Kept until appended; a newer copy of a kept one rides beside it (ingestion offers each id once).
            if !pendingMessages.contains(message) { pendingMessages.append(message) }
        }
        let result: JSONValue
        if let pull { result = try await pull.value } else {
            let task = Task { try await self.drain(peer: peer) }
            pull = task
            result = try await task.value
        }
        let shown = if let window { try await readWindow(peer: peer, window: window) } else { result }
        let last = try ContactThread.lines(dataRoot: dataRoot, owner: peer.id).last
        return AgentConversationView.dotReply(shown, sentAt: last?.mine == true ? last?.at : nil)
    }

    private func readWindow(peer: AgentPeerContact, window: [String: JSONValue]) async throws -> JSONValue {
        let session = principal(peer).storedConversation("mcp-" + peer.id)
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
        let source = try await SwiftNativePersistenceCore.readJSONLReporting(transcript)
        let saved = ContactThread.project(source.rows.reversed().compactMap { value -> ContactThread.Line? in
            guard case .object(let row) = value,
                  row["role"] == .string("user") || row["role"] == .string("assistant"),
                  case .string? = row["content"] else { return nil }
            return ContactThread.Line(row)
        }, own: PersonaCompiler.agentDisplayName(dataRoot: dataRoot), names: ["peer:" + peer.id: peer.name])
        let rows = saved.map { line -> [String: JSONValue] in
            ["id": line.id.isEmpty ? .null : .string(line.id), "at": line.timestamp.map(JSONValue.string) ?? .null,
             "from": .string(line.speaker), "own": .bool(line.mine), "text": .string(line.text)]
        }
        let version = SHA256.hash(data: try JSONValue.array(rows.map { .object($0) }).serializedData(pretty: false))
            .map { String(format: "%02x", $0) }.joined()
        if let expected = window["source_version"], expected != .string(version) {
            throw AgentConversationStore.Failure(message: "Dot's retained conversation changed. Read again without source_version, offset or text_offset, then follow the new next; no characters from a different message were substituted.")
        }
        func integer(_ key: String) -> Int {
            if case .int(let value)? = window[key] { return Int(value) }
            return 0
        }
        let offset = integer("offset"), limit = integer("limit"), maxChars = integer("max_chars")
        var index = min(offset, rows.count), textOffset = integer("text_offset"), remaining = maxChars
        var selected: [JSONValue] = []
        while index < rows.count, selected.count < limit, remaining > 0 {
            var row = rows[index]
            guard case .string(let text)? = row["text"] else { break }
            guard textOffset <= text.count else {
                throw AgentConversationStore.Failure(message: "Dot's text_offset is beyond this message. Read Dot again with text_offset:0.")
            }
            let part = String(text.dropFirst(textOffset).prefix(remaining))
            row["text"] = .string(part)
            row["text_offset"] = .int(Int64(textOffset))
            row["text_has_more"] = .bool(textOffset + part.count < text.count)
            selected.append(.object(row))
            ContactThread.consume(saved[index], mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) })
            remaining -= part.count
            textOffset += part.count
            if textOffset < text.count { break }
            index += 1; textOffset = 0
        }
        var result: [String: JSONValue] = ["status": .string("ready"), "agent": .string(peer.name),
            "agent_id": .string("peer:" + peer.id), "conversation_id": .string(session),
            "untrusted_remote_data": .bool(true), "conversation": .array(selected.reversed()),
            "offset": .int(Int64(offset)), "returned": .int(Int64(selected.count)),
            "has_more": .bool(index < rows.count), "coverage": .string("retained conversation slice"),
            "source_version": .string(version),
            "window_order": .string("offset counts messages from newest; returned messages are chronological"),
            "source_malformed_rows": .int(Int64(source.report.malformedLineCount)),
            "source_trailing_partial_line": .bool(source.report.trailingPartialLine)]
        if index < rows.count {
            result["next"] = .object(["agent": .string("peer:" + peer.id), "conversation_id": .string(session),
                "offset": .int(Int64(index)), "limit": .int(Int64(limit)), "max_chars": .int(Int64(maxChars)),
                "text_offset": .int(Int64(textOffset)), "source_version": .string(version)])
        }
        return .object(result)
    }

    private func drain(peer: AgentPeerContact) async throws -> JSONValue {
        defer { pull = nil }
        var result: JSONValue
        // Taken only once in her session: a failed append keeps them for the next event.
        repeat {
            let messages = pendingMessages
            result = try await append(messages, peer: peer)
            pendingMessages.removeFirst(messages.count)
        } while !pendingMessages.isEmpty
        return result
    }

    private func principal(_ peer: AgentPeerContact) -> AgentBridgePrincipal {
        .init(id: peer.id, peerID: peer.id, elevated: peer.elevationAllowed, displayName: peer.name)
    }

    private func append(_ messages: [JSONValue], peer: AgentPeerContact,
                        recovery: UUID? = nil) async throws -> JSONValue {
        func checkRecovery() throws {
            guard !retired else { throw CancellationError() }
            try Task.checkCancellation()
            if let recovery, !isCurrent(recovery) || Task.isCancelled { throw CancellationError() }
        }
        try checkRecovery()
        // Recheck the saved contact and Trust at ingestion, after the read-only IPC follow.
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peer.id }),
              ChatGPTDotIPCTransport.owns(peer) else {
            throw AgentConversationStore.Failure(message: "Dot's contact is no longer connected.")
        }
        let principal = principal(peer), context = "mcp-" + peer.id
        let session = principal.storedConversation(context)
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
        var rows = try await SwiftNativePersistenceCore.readJSONL(transcript)
        try checkRecovery()
        let replies = try replies(messages, rows: rows)
        var replyRows: [String: [JSONValue]] = [:], startedRuns: Set<String> = []
        for value in rows {
            if let id = Self.replyID(value) { replyRows[id, default: []].append(value) }
            if case .object(let row) = value, case .string(let run)? = row["runId"],
               row["role"] != .string("user") { startedRuns.insert(run) }
        }
        var durableIDs = Set(replyRows.keys)
        let client = clients.bridgeChatClient()
        var appended = false
        let pending = try admissions(peer: peer.id)
        let recovered = try pending.values.filter { !$0.started && $0.failed == nil }.map { admission -> (JSONValue, Date) in
            guard case .object(let fields) = admission.message, case .string(let at)? = fields["at"],
                  let date = roomDate(at) else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            return (admission.message, date)
        }.sorted { $0.1 < $1.1 }.map { $0.0 }
        var offered: Set<String> = []
        for message in recovered + replies {
            try checkRecovery()
            guard case .object(let fields) = message, case .string(let roomID)? = fields["id"],
                  case .string(let text)? = fields["text"] else {
                throw AgentConversationStore.Failure(message: "Dot returned an unreadable room message.")
            }
            let id = "dot-room:" + roomID
            let key = peer.id + ":" + id
            guard offered.insert(id).inserted, admissionTasks[key] == nil else { continue }
            if pending[id]?.started == true { continue }
            if durableIDs.contains(id), pending[id] == nil { continue }
            let failed = pending[id]?.failed
            if failed != nil { continue }
            let lifeID = try DataRootLife.current(in: dataRoot)
            // His reply is a message in her Dot session that wakes her, like any
            // contact's; she answers him with agent_message when she wants to.
            let turn = AgentContactTurn(taskID: UUID().uuidString, context: context, requestID: id, principal: principal,
                parts: [.text(text + "\n\n(Dot sees your answer only if you send it to him with agent_message.)")],
                bindRun: { _, _ in try await self.startAdmission(id: id, peer: peer.id) })
            let plain = turn.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            let request = principal.turnRequest(context: context, plain: plain,
                messageID: id, originID: id)
            if pending[id] == nil { try updateAdmissions(peer: peer.id) { $0[id] = Admission(lifeID: lifeID, message: message) } }
            var enqueued: EnqueuedUserMessage?
            let savedRows = replyRows[id] ?? []
            if !savedRows.isEmpty, failed == nil {
                guard savedRows.count == 1, case .object(let row) = savedRows[0],
                      case .string(let run)? = row["runId"] else {
                    throw AgentConversationStore.Failure(message: "Dot's saved reply has no unique enqueued turn.")
                }
                // A non-user row proves the run already began.
                if startedRuns.contains(run) {
                    try startAdmission(id: id, peer: peer.id)
                    continue
                }
                enqueued = .init(sessionId: session, runId: run)
            }
            admissionTasks[key] = AdmissionWork()
            let accepted: EnqueuedUserMessage
            do {
                if let enqueued { accepted = enqueued }
                else { accepted = try await request.enqueue(on: client) }
            } catch { admissionTasks.removeValue(forKey: key); throw error }
            durableIDs.insert(id)
            // Enqueue may have committed while Stop arrived. Keep that row
            // and its saved admission for restart, but admit no new turn.
            do { try checkRecovery() }
            catch { admissionTasks.removeValue(forKey: key); throw error }
            let root = dataRoot
            admissionTasks[key] = AdmissionWork(task: Task {
                defer { admissionTasks.removeValue(forKey: key) }
                guard !retired, !Task.isCancelled else { return }
                // Admission owns capacity waiting for this exact saved row.
                var failed: String?
                var retryCause: ProviderFailure?
                do {
                    let outcome = try await AgentContactRuntime.run(turn, client: client, dataRoot: root,
                                                                   enqueued: accepted, emit: { _ in })
                    if outcome.state == .failed {
                        failed = outcome.detail ?? "The turn did not finish."
                        retryCause = outcome.failure?.cause
                    }
                } catch is CancellationError { return } catch {
                    failed = error.localizedDescription
                    retryCause = ProviderFailure.classify(error)
                    nativeLog("Dot admission failed: %@", error.localizedDescription)
                }
                do { try updateAdmissions(peer: peer.id) { $0[id] = failed.map { Admission(lifeID: lifeID,
                    message: message, started: true, failed: $0, retryCause: retryCause) } } }
                catch { nativeLog("Dot admission could not be saved: %@", error.localizedDescription); return }
            })
            appended = true
        }
        if appended {
            AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, inbound: true)
        }
        rows = try await SwiftNativePersistenceCore.tailJSONL(transcript, limit: 100, maxBytes: 1_048_576)
        let agentName = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
        return .object(["status": .string("ready"), "agent": .string(peer.name), "agent_id": .string("peer:" + peer.id),
                        "conversation_id": .string(session), "untrusted_remote_data": .bool(true),
                        "conversation": .array(ContactThread.project(rows.compactMap { value -> ContactThread.Line? in
                            guard case .object(let row) = value,
                                  row["role"] == .string("user") || row["role"] == .string("assistant"),
                                  case .string? = row["content"] else { return nil }
                            return ContactThread.Line(row)
                        }, own: PersonaCompiler.agentDisplayName(dataRoot: dataRoot), names: ["peer:" + peer.id: peer.name],
                            mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) }).map { line in
                            .object(["id": line.id.isEmpty ? .null : .string(line.id), "at": line.timestamp.map(JSONValue.string) ?? .null,
                                     "from": .string(line.speaker), "own": .bool(line.mine), "text": .string(line.text)])
                        })])
    }

    private static func replyID(_ value: JSONValue) -> String? {
        guard case .object(let row) = value, row["role"] == .string("user"),
              case .object(let metadata)? = row["metadata"], case .object(let origin)? = metadata["origin"],
              case .string(let id)? = origin["replyTo"], id.hasPrefix("dot-room:") else { return nil }
        return id
    }

    private func roomDate(_ text: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(text)
    }

    private func replies(_ messages: [JSONValue], rows: [JSONValue]) throws -> [JSONValue] {
        var sentIDs = Set<String>()
        for row in rows {
            guard case .object(let row) = row, row["role"] == .string("assistant"),
                  row["source"] == .string("agent-bridge") else { continue }
            if case .object(let metadata)? = row["metadata"], case .string(let id)? = metadata["dotClientUserMessageID"] {
                sentIDs.insert(id)
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
        let recipient = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (message, fields, date) in timeline {
            if fields["kind"] == .string("user") {
                let ownSend: Bool
                if case .string(let id)? = fields["client_id"], sentIDs.contains(id) {
                    ownSend = true
                } else { ownSend = false }
                afterSend = ownSend ? date : nil
            } else if fields["kind"] == .string("dot") {
                // An answer to our send, or an address to the configured resident.
                let text = (fields["text"].flatMap { if case .string(let t) = $0 { return t }; return nil } ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let address = text.hasPrefix("@") ? String(text.dropFirst()) : text
                let boundary = address.dropFirst(recipient.count).first
                let addressed = !recipient.isEmpty && address.hasPrefix(recipient)
                    && (boundary == nil || boundary?.isWhitespace == true || boundary?.isPunctuation == true)
                if addressed || afterSend.map({ date > $0 }) == true { replies.append(message) }
            }
        }
        return replies
    }

}
