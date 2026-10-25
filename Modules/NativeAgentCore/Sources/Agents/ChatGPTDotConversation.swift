import ChatTurnRuntime
import ChatTurnContracts
import AgentWorkspace
import AgentConversations
import CryptoKit
import Foundation
import Network
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import Transcripts
// Blueprint: | `ChatGPTDotConversation.swift` | `ChatGPTDotConversation` actor; `refresh`, `conversation`; saved arrivals wait on `TurnAdmission` capacity signals; cached failed-admission peer IDs gate link recovery before peer/file reads; room cleanup keeps the first revised message per ID; successful recovery owns network/provider subscriptions until retirement, which releases recovery admission on failure, cancellation and stop; the delegation runner stops subscriptions with discovery and Dot socket observation; old lifecycle callbacks cannot retry admissions |

/// Dot's room is an ingress into his ordinary contact session, not an outbound reply tracker.
actor ChatGPTDotConversation {
    let dataRoot: URL
    let clients: any AgentContactClients
    private var pull: Task<JSONValue, Error>?
    private var pendingMessages: [JSONValue] = []
    private struct Admission: Codable {
        var lifeID: String?
        let message: JSONValue
        var started = false
        /// Why the turn it began did not finish (her model link dropped).
        /// It runs again once the network is back, not on the next room change.
        var failed: String?
    }
    private var admissionTasks: Set<String> = []
    private var link: NWPathMonitor?
    private var linkChanges: Task<Void, Never>?
    private var providerChanges: Task<Void, Never>?
    private var generation = UUID()
    private var recoveryAttempted = false
    /// The link is back: the network path came up (when), or her newest
    /// provider call anywhere succeeded.
    private var pathUp: Date?
    private var providerFine = false
    /// Retried at once after failing (below); again only after a fresh link event.
    private var retriedAtOnce: Set<String> = []
    /// Seeded at launch, then maintained with admission reads and durable writes.
    /// Provider successes app-wide must not scan peers or files when none failed.
    private var failedAdmissionPeers: Set<String> = []
    private var retryingAdmissions = false

    init(dataRoot: URL, clients: any AgentContactClients) {
        self.dataRoot = dataRoot
        self.clients = clients
    }

    /// At launch. A message whose turn began in an earlier run of the app and
    /// never finished waits for the link like one whose turn failed on it.
    func resumeAdmissions() async throws {
        guard !recoveryAttempted, !Task.isCancelled else { return }
        recoveryAttempted = true
        let generation = generation
        // Reserve this lifecycle before the recovery pass suspends.
        let link = NWPathMonitor()
        self.link = link
        do {
            for peer in try AgentPeerStore(dataRoot: dataRoot).list() where ChatGPTDotIPCTransport.owns(peer) {
                for (id, admission) in try admissions(peer: peer.id)
                    where try admission.started && DataRootLife.isCurrent(admission.lifeID, in: dataRoot)
                        && !admissionTasks.contains(peer.id + ":" + id) {
                    try saveAdmission(Admission(lifeID: admission.lifeID, message: admission.message, failed: "The app stopped before it finished."), id: id, peer: peer.id)
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
        // The link is back when the network path comes up (its state now
        // counts), or when a call to her model provider succeeds: a provider
        // timeout recovers with the path unchanged.
        let paths = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        link.pathUpdateHandler = { path in
            if path.status == .satisfied { paths.continuation.yield(()) }
        }
        linkChanges = Task { [weak self] in
            defer { paths.continuation.finish() }
            for await _ in paths.stream {
                guard let self, await self.isCurrent(generation), !Task.isCancelled else { return }
                await self.linkBack(path: true, generation: generation)
            }
        }
        link.start(queue: DispatchQueue(label: "ChatGPTDotConversation.link"))
        self.link = link
        let clients = clients
        providerChanges = Task { [weak self] in await self?.followProvider(clients, generation: generation) }
    }

    private func followProvider(_ clients: any AgentContactClients, generation: UUID) async {
        defer { if self.generation == generation { providerChanges = nil } }
        guard let changes = await clients.cognitionChanges(), isCurrent(generation), !Task.isCancelled else { return }
        for await change in changes {
            guard isCurrent(generation), !Task.isCancelled else { return }
            switch change.reason {
            case "provider_lifecycle:succeeded": await linkBack(path: false, generation: generation)
            case "provider_lifecycle:failed": providerFailed(generation: generation)
            default: break
            }
        }
    }

    func stopSubscriptions() {
        retireSubscriptions()
    }

    private func retireSubscriptions() {
        recoveryAttempted = false
        generation = UUID()
        link?.pathUpdateHandler = nil
        link?.cancel(); link = nil
        linkChanges?.cancel(); linkChanges = nil
        providerChanges?.cancel(); providerChanges = nil
        providerFine = false; pathUp = nil
    }

    private func isCurrent(_ generation: UUID) -> Bool { self.generation == generation && link != nil }

    private func providerFailed(generation: UUID) {
        guard isCurrent(generation), !Task.isCancelled else { return }
        providerFine = false
    }

    private func linkBack(path: Bool, generation: UUID) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        if path { pathUp = Date() } else { providerFine = true }
        retriedAtOnce.removeAll()
        guard !failedAdmissionPeers.isEmpty else { return }
        do { try await retryAdmissions() }
        catch { nativeLog("Dot admission retry failed: %@", error.localizedDescription) }
    }

    private func retryAdmissions() async throws {
        guard link != nil, !Task.isCancelled, !failedAdmissionPeers.isEmpty, !retryingAdmissions else { return }
        let generation = generation
        retryingAdmissions = true
        defer { retryingAdmissions = false }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list().filter { ChatGPTDotIPCTransport.owns($0) }
        failedAdmissionPeers.formIntersection(peers.map(\.id))
        for peer in peers where failedAdmissionPeers.contains(peer.id) {
            guard isCurrent(generation), !Task.isCancelled else { return }
            if try admissions(peer: peer.id).values.contains(where: { !$0.started && $0.failed != nil }) {
                _ = try await append([], peer: peer, retry: true, recovery: generation)
            }
        }
    }

    private func admissionFile(peer: String) -> URL {
        dataRoot.appendingPathComponent("agent-conversations/dot-admission-\(peer).json")
    }

    private func admissions(peer: String) throws -> [String: Admission] {
        let file = admissionFile(peer: peer)
        guard FileManager.default.fileExists(atPath: file.path) else {
            failedAdmissionPeers.remove(peer)
            return [:]
        }
        var saved = try JSONDecoder().decode([String: Admission].self, from: Data(contentsOf: file))
        for id in saved.keys where try !DataRootLife.isCurrent(saved[id]?.lifeID, in: dataRoot) {
            saved[id]?.started = true
            saved[id]?.failed = DataRootLife.stoppedReason
        }
        cacheFailedAdmissions(saved, peer: peer)
        return saved
    }

    private func cacheFailedAdmissions(_ saved: [String: Admission], peer: String) {
        if saved.values.contains(where: { !$0.started && $0.failed != nil }) {
            failedAdmissionPeers.insert(peer)
        } else {
            failedAdmissionPeers.remove(peer)
        }
    }

    private func saveAdmission(_ admission: Admission?, id: String, peer: String) throws {
        var saved = try admissions(peer: peer)
        saved[id] = admission
        let file = admissionFile(peer: peer)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(saved), to: file)
        cacheFailedAdmissions(saved, peer: peer)
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

    func conversation(root: URL, peer: AgentPeerContact, messages: [JSONValue], sent: String?, window: [String: JSONValue]? = nil) async throws -> JSONValue {
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
        let source = try await SwiftNativePersistenceCore().readJSONLReporting(transcript)
        let saved = ContactThread.project(source.rows.reversed().compactMap { value -> ContactThread.Line? in
            guard case .object(let row) = value,
                  row["role"] == .string("user") || row["role"] == .string("assistant"),
                  case .string? = row["content"] else { return nil }
            return ContactThread.Line(row)
        }, own: PersonaCompiler.agentDisplayName(dataRoot: dataRoot), names: ["peer:" + peer.id: peer.name])
        let rows = saved.map { line -> [String: JSONValue] in
            ["id": line.id.isEmpty ? .null : .string(line.id), "at": line.timestamp.map(JSONValue.string) ?? .null,
             "from": .string(line.speaker), "text": .string(line.text)]
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

    /// `retry`: the link is back, so messages whose turn failed on it run again.
    private func append(_ messages: [JSONValue], peer: AgentPeerContact, retry: Bool = false,
                        recovery: UUID? = nil) async throws -> JSONValue {
        func checkRecovery() throws {
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
        let persistence = SwiftNativePersistenceCore()
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
        let seenFile = dataRoot.appendingPathComponent("agent-conversations/dot-seen-\(peer.id).json")
        let seen: [String]
        if FileManager.default.fileExists(atPath: seenFile.path) {
            seen = try JSONDecoder().decode([String].self, from: Data(contentsOf: seenFile))
        } else { seen = [] }
        var rows = try await persistence.readJSONL(transcript)
        try checkRecovery()
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
            try checkRecovery()
            try await persistence.writeJSON(.bool(true), to: cleanupFile)
            try checkRecovery()
            rows = try await persistence.readJSONL(transcript)
            try checkRecovery()
            durableIDs = Set(rows.compactMap(Self.replyID))
        }
        let client = clients.bridgeChatClient()
        var appended = false
        let pending = try admissions(peer: peer.id)
        let recovered = try pending.values.filter { !$0.started && (retry || $0.failed == nil) }.map { admission -> (JSONValue, Date) in
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
            guard offered.insert(id).inserted, !admissionTasks.contains(key) else { continue }
            if pending[id]?.started == true { continue }
            if durableIDs.contains(id), pending[id] == nil { continue }
            let failed = pending[id]?.failed
            if failed != nil, !retry { continue }
            let lifeID = try DataRootLife.current(in: dataRoot)
            // His reply is a message in her Dot session that wakes her, like any
            // contact's; she answers him with agent_message when she wants to.
            // A retry is a new turn: the one before it ended, and may have done things.
            let again = failed.map { "\n\n(This reached you before, but that turn did not finish: \($0) Some steps may already have run; check before repeating them.)" } ?? ""
            let turn = AgentContactTurn(taskID: UUID().uuidString, context: context, requestID: id, principal: principal,
                parts: [.text(text + "\n\n(Dot sees your answer only if you send it to him with agent_message.)" + again)],
                bindRun: { _, _ in try await self.startAdmission(id: id, peer: peer.id) })
            let plain = turn.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            let request = principal.turnRequest(context: context, plain: plain,
                messageID: id, originID: id)
            if pending[id] == nil { try saveAdmission(Admission(lifeID: lifeID, message: message), id: id, peer: peer.id) }
            var enqueued: EnqueuedUserMessage?
            let savedRows = rows.filter { Self.replyID($0) == id }
            if !savedRows.isEmpty, failed == nil {
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
                let began = Date()
                // Admission owns capacity waiting for this exact saved row.
                var failed: String?
                do {
                    let outcome = try await AgentContactRuntime.run(turn, client: client, dataRoot: root,
                                                                   enqueued: accepted, emit: { _ in })
                    if outcome.state == .failed { failed = outcome.detail ?? "The turn did not finish." }
                } catch is CancellationError { return } catch {
                    if ProviderFailure.classify(error) == .network { failed = error.localizedDescription }
                    else { nativeLog("Dot admission failed: %@", error.localizedDescription) }
                }
                do { try saveAdmission(failed.map { Admission(lifeID: lifeID, message: message, failed: $0) }, id: id, peer: peer.id) }
                catch { nativeLog("Dot admission could not be saved: %@", error.localizedDescription); return }
                // The link may have come back while this turn was failing: that
                // event found nothing saved yet. Retry after this task lets go.
                if failed != nil, providerFine || (pathUp ?? .distantPast) > began,
                   retriedAtOnce.insert(key).inserted {
                    Task { try? await self.retryAdmissions() }
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
                                     "from": .string(line.speaker), "text": .string(line.text)])
                        })])
    }

    private static func replyID(_ value: JSONValue) -> String? {
        guard case .object(let row) = value, row["role"] == .string("user"),
              case .object(let metadata)? = row["metadata"], case .object(let origin)? = metadata["origin"],
              case .string(let id)? = origin["replyTo"], id.hasPrefix("dot-room:") else { return nil }
        return id
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
                // His answer to her ask, or Dot's fixed routing address ("Agent, …") at any time.
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
        let timestamps = Dictionary(replies.compactMap { message -> (String, String)? in
            guard case .object(let fields) = message, case .string(let id)? = fields["id"],
                  case .string(let at)? = fields["at"] else { return nil }
            return ("dot-room:" + id, at)
        }, uniquingKeysWith: { first, _ in first })
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
            if changed { try ContactThread.replace(Data(output.utf8), to: transcript) }
            return changed
        }
        if changed { NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: transcript.deletingPathExtension().lastPathComponent) }
    }
}
