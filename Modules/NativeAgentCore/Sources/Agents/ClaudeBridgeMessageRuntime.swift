import Foundation
import ChatToolParsing
import ChatTurnContracts
import Darwin
import CryptoKit
import ChatTurnRuntime
import AgentConversations
import AgentWorkspace
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import TurnTrace
import Transcripts
import Experiences
// Blueprint: | `ClaudeBridgeMessageRuntime.swift` | HTTP waits never own accepted turns. |

/// Authenticate before transport selection and delivery projection enter the conversation owner.
public protocol ClaudeBridgeMessagePort: Sendable {
    func activeSessionID(dataRoot: URL) throws -> String?
    func activePersona(dataRoot: URL) throws -> String?
    func chatClient() -> SwiftNativeChatOrchestrationClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func publishChatTurnCompleted(sessionID: String?) async
}

/// Retained task admission, execution and durable receipts belong to AgentContactTasks, not HTTP routing.
public final class ClaudeBridgeMessageRuntime: @unchecked Sendable {
    public typealias Response = @Sendable (Int, [String: Any], @escaping @Sendable (Bool) -> Void) -> Void
    private typealias PreparedResponse = @Sendable (Int, [String: Any]) -> Void
    private let port: any ClaudeBridgeMessagePort
    private let tasks: AgentContactTasks
    private let eventPublisher: @Sendable (String, [String: Any]) -> Void
    private let clientLock = NSLock()
    private var cachedChatClient: (SwiftNativeChatOrchestrationClient)?


    public init(port: any ClaudeBridgeMessagePort, tasks: AgentContactTasks,
                eventPublisher: @escaping @Sendable (String, [String: Any]) -> Void) {
        self.port = port
        self.tasks = tasks
        self.eventPublisher = eventPublisher
    }

    private func chatClient() -> SwiftNativeChatOrchestrationClient {
        clientLock.withLock {
            if let cachedChatClient { return cachedChatClient }
            let client = port.chatClient()
            cachedChatClient = client
            return client
        }
    }

    /// Replay evidence binds authenticated caller, protocol and exact bytes; the shared bridge bearer cannot attest a peer.
    public struct PeerTurnContext: Sendable {
        public let principal: AgentBridgePrincipal
        public let protocolName: String
        public let bodyDigest: String

        public init(principal: AgentBridgePrincipal, protocolName: String, bodyDigest: String) {
            self.principal = principal
            self.protocolName = protocolName
            self.bodyDigest = bodyDigest
        }
    }

    public static func validGenericAgentMessage(_ json: [String: Any]) -> Bool {
        guard Set(json.keys).isSubset(of: ["text", "sessionId", "request_id"]),
              let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64000 else { return false }
        if let raw = json["sessionId"] {
            guard let session = raw as? String, genericAgentSessionID(requested: session) != nil else { return false }
        }
        if let raw = json["request_id"] {
            guard let id = raw as? String, UUID(uuidString: id) != nil else { return false }
        }
        return true
    }

    /// Continue supplied mounted-surface identity exactly or refuse it; never substitute the selected chat. Requested IDs require the authenticated owner
    /// prefix; acknowledgements retain newly created IDs.
    public static func genericAgentSessionID(requested: String?, owner: String? = nil) -> String? {
        let prefix = owner.map { AgentBridgePrincipal.genericAgentSessionPrefix(owner: $0) }
        guard let requested else {
            return (prefix ?? "") + (owner.map { "mcp-" + $0 } ?? UUID().uuidString.lowercased())
        }
        guard requested.utf8.count <= 128,
              NativeAgentChatSessionID.normalizedPathComponent(requested) == requested else { return nil }
        if let prefix, !requested.hasPrefix(prefix) { return nil }
        return requested
    }

    public func handleMessage(response sendResponse: @escaping Response, body: Data, defaultSender: String, principal: AgentBridgePrincipal) {
        @Sendable func response(_ status: Int, _ object: [String: Any]) {
            let dataRoot = PersistenceCore.defaultDataRoot()
            do {
                let held = try AgentContactHeldResponse(principal: principal, dataRoot: dataRoot, via: "/" + defaultSender + "/message")
                sendResponse(status, held.adding(to: object), held.settle)
            } catch {
                sendResponse(503, AgentContactHeldResponse.failure(error, dataRoot: dataRoot), { _ in })
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            response(400, ["error": "invalid_json"])
            return
        }
        guard let rawText = json["text"] as? String, !rawText.isEmpty else {
            response(400, ["error": "missing_text"])
            return
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let owner: String
        do { owner = try AgentContactIdentity(dataRoot: dataRoot).canonical("peer:" + principal.id) }
        catch { response(503, ["error": "contact_identity_unavailable", "detail": error.localizedDescription]); return }
        let threadOwner = owner.hasPrefix("peer:") ? String(owner.dropFirst(5)) : owner
        let requestedSessionId = json["sessionId"] as? String
        // Bound local image attachment reads to four files of 8 MB each and report skipped images.
        let preparedImages = Self.prepareBridgeImages(json["image_paths"] as? [String] ?? [])
        let attachments = preparedImages.attachments
        let imageSkips = preparedImages.skips
        // Only allowlisted script senders may override the route's sender name.
        let sender: String = {
            if let named = (json["sender"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               Self.scriptSenders.contains(named) {
                return named
            }
            return defaultSender
        }()
        // Peers default to their own conversation; scripts use the active chat.
        let selectedSession: String?
        do {
            if requestedSessionId != nil { selectedSession = nil }
            else if sender == defaultSender { selectedSession = ContactThread.session(owner: threadOwner) }
            else { selectedSession = try port.activeSessionID(dataRoot: dataRoot) }
        } catch {
            response(503, ["error": "active_session_unavailable",
                "detail": "The selected chat could not be read: \(error.localizedDescription). Repair the session index before retrying."]); return
        }
        let sessionId = Self.bridgeMessageSessionID(
            requested: requestedSessionId,
            active: selectedSession
        )
        if sessionId == nil {
            response(409, [
                "error": "no_active_chat_session",
                "detail": "Create or select a chat in NativeAgent, then retry.",
            ])
            return
        }
        let claudeReplyID: String?
        do { claudeReplyID = try Self.claudeReplyID(json, owner: owner) }
        catch { response(503, ["error": "reply_identity_unavailable", "detail": error.localizedDescription]); return }
        if let claudeReplyID, attachments.isEmpty {
            let from = principal.peerID.map { "peer:" + $0 } ?? "another agent"
            do {
                if try AgentConversationStore(dataRoot: dataRoot).offerBridgeReplyToInlineWait(
                    agent: owner, messageID: claudeReplyID, text: rawText, from: from, steeredBy: [from]) {
                    response(200, ["status": "ok", "ack": "answered_inline", "messageId": claudeReplyID])
                    return
                }
            } catch {
                response(503, ["error": "reply_handoff_failed", "detail": error.localizedDescription])
                return
            }
        }
        let selectedPersona: String?
        do { selectedPersona = try port.activePersona(dataRoot: dataRoot) }
        catch {
            response(503, ["error": "active_persona_unavailable",
                "detail": "The selected persona could not be read: \(error.localizedDescription). Repair the persona selection before retrying."]); return
        }
        let baseRequest: TurnRequest = {
            var request = principal.turnRequest(context: nil, plain: rawText, attachments: attachments, originID: claudeReplyID)
            request.sessionID = sessionId
            request.ownedSessionID = ContactThread.session(owner: threadOwner)
            request.verifiedSessionID = .some(sessionId)
            request.persona = selectedPersona
            request.message = Self.withImageSkipNote(request.message, imageSkips)
            return request
        }()
        let text = baseRequest.message
        let started = Date()
        let requestID = UUID().uuidString
        eventPublisher("message_in", [
            "requestId": requestID,
            "sender": sender,
            "textLen": text.count,
            "sessionId": sessionId ?? NSNull(),
        ])
        let ackMode = (json["ackMode"] as? String)?.lowercased()
        let requestIdentity: String
        if let supplied = json["request_id"] {
            guard let value = supplied as? String, UUID(uuidString: value) != nil else {
                response(400, ["error": "invalid_request_id"]); return
            }
            requestIdentity = value
        } else { requestIdentity = requestID }
        handleRetainedMessage(response: response, request: baseRequest, principal: principal, owner: owner,
            claudeReplyID: claudeReplyID, rawText: rawText, requestID: requestIdentity,
            started: started, digest: AgentPeerReplayClaimStore.digest(body), ackMode: ackMode)
    }

    static func bridgeMessageSessionID(requested: String?, active: String?) -> String? {
        for candidate in [requested, active] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public static func messageReplyURL(home: URL? = nil) -> URL {
        let root = home.map { InstallPaths(home: $0).bridgeConfigRoot }
            ?? InstallPaths.current.bridgeConfigRoot(dataRoot: PersistenceCore.defaultDataRoot())
        return root.appendingPathComponent("claude-bridge/message-replies.jsonl")
    }

    /// Read bounded existing receipts without replay or another store; damaged scope proves neither absence nor uniqueness. Match only the authenticated
    /// principal, even when another caller reused the same IDs.
    public static func agentReplyReceipt(requestID: String, sessionID: String, offset: Int = 0,
                                  maxChars: Int = 8000, logURL: URL, principal: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["request_id": requestID, "session_id": sessionID,
            "status": "unavailable", "original_outcome": "unknown",
            "detail": "A missing receipt does not prove failure or authorize replay."]
        func finish(_ evidence: String, complete: Bool = false) -> [String: Any] {
            var value = result
            value["evidence"] = evidence
            value["coverage"] = ["complete": complete, "scope": "retained_reply_receipts"]
            value["retrieval_result_class"] = result["status"] as? String == "ok" ? "succeeded" : "failed"
            return value
        }
        guard !requestID.isEmpty, requestID.utf8.count <= 128,
              !sessionID.isEmpty, sessionID.utf8.count <= 128,
              offset >= 0, offset <= 1_048_576, (1...16000).contains(maxChars) else {
            result["status"] = "invalid_request"
            return finish("invalid_request")
        }
        let fd = Darwin.open(logURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                result["status"] = "not_found"
                return finish("no_retained_receipt", complete: true)
            }
            return finish("unreadable_receipts")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return finish("unreadable_receipts") }
        let maximumScanBytes = 16 * 1_048_576
        let maximumRowBytes = 1_048_576
        guard before.st_size <= maximumScanBytes else { return finish("scan_limit") }
        var pending = Data()
        var total = 0
        var matches = 0
        var matched: [String: Any]?
        func inspect(_ line: Data) -> String? {
            guard line.count <= maximumRowBytes else { return "row_limit" }
            if line.isEmpty { return nil }
            guard let text = String(data: line, encoding: .utf8) else { return "invalid_encoding" }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return "malformed_receipts" }
            // Validate payloads only after request identity matches; malformed JSON invalidates scope.
            if let rawID = row["requestId"], !(rawID is String) { return "malformed_receipts" }
            guard row["requestId"] as? String == requestID else { return nil }
            if let principal, row["principal"] as? String != principal { return nil }
            matches += 1
            guard let rowSession = row["sessionId"] as? String,
                  let status = row["status"] as? String, !status.isEmpty,
                  row["reply"] is String else { return "malformed_receipts" }
            if rowSession == sessionID { matched = row }
            return nil
        }
        do {
            while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                total += chunk.count
                guard total <= maximumScanBytes else { return finish("scan_limit") }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    if let error = inspect(Data(pending[..<newline])) { return finish(error) }
                    pending.removeSubrange(...newline)
                }
                guard pending.count <= maximumRowBytes else { return finish("row_limit") }
            }
            if !pending.isEmpty, let error = inspect(pending) { return finish(error) }
        } catch { return finish("unreadable_receipts") }
        var after = stat()
        var current = stat()
        guard fstat(fd, &after) == 0, lstat(logURL.path, &current) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_ino == current.st_ino, after.st_dev == current.st_dev else { return finish("receipts_changed") }
        guard matches <= 1 else { return finish("ambiguous_receipt", complete: true) }
        guard let row = matched, let reply = row["reply"] as? String else {
            result["status"] = "not_found"
            return finish("no_retained_receipt", complete: true)
        }
        guard offset <= reply.count else {
            result["status"] = "invalid_request"
            return finish("offset_out_of_range", complete: true)
        }
        let slice = String(reply.dropFirst(offset).prefix(maxChars))
        result["status"] = "ok"
        result.removeValue(forKey: "original_outcome")
        result["original_status"] = row["status"]
        // Combined delivery wording proves neither execution nor settlement.
        result["execution_result_class"] = row["execution_result_class"] ?? "unknown"
        result["execution_terminal"] = row["execution_terminal"] ?? NSNull()
        for key in ["attachments", "completionDelivery", "deliveryId"] { result[key] = row[key] }
        result["run_id"] = row["runId"] as? String ?? NSNull()
        result["reply"] = slice
        result["offset"] = offset
        result["next_offset"] = offset + slice.count
        result["has_more"] = offset + slice.count < reply.count
        return finish("exact_receipt", complete: true)
    }

    static func messageReplyRecord(_ payload: [String: Any], requestID: String) -> [String: Any] {
        var record = payload
        record["requestId"] = requestID
        record["execution_result_class"] = ChatToolOutcome.exactResultClass(.object(["status": .string(payload["status"] as? String ?? "")])).rawValue
        record["execution_terminal"] = true
        return record
    }

    /// Both HTTP response modes settle through the same owner, independently of acknowledgement.
    private func settleMessageReply(turn: Turn, _ resp: ChatTurnRuntime.ChatResponse, request: TurnRequest,
        principal: AgentBridgePrincipal, owner: String, claudeReplyID: String?, replyText: String,
        requestID: String, started: Date, sessionID: String?, enqueued: Bool = false) async throws -> [String: Any] {
        let turnSession = resp.sessionId ?? sessionID
        await port.publishChatTurnCompleted(sessionID: turnSession)
        try await Self.settleContactReply(turn: turn, resp, request: request, principal: principal, owner: owner,
            replyID: claudeReplyID, replyText: replyText, session: turnSession, client: chatClient(),
            sender: port.completionSender(dataRoot: portDataRoot))
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let reply = ChatResponse.answerOnly(resp.output, workingCommentaryCharacters: resp.workingCommentaryCharacters)
        let attachments = Self.bridgeAttachmentPayload(resp.attachments)
        let status = resp.terminalState?.rawValue ?? "incomplete"
        var result = Self.messageReplyRecord(["status": status,
            "sessionId": (enqueued ? turnSession : resp.sessionId) ?? NSNull(),
            "model": resp.model, "runId": resp.runId, "durationMs": durationMs,
            "reply": reply, "attachments": attachments], requestID: requestID)
        if enqueued { result["ack"] = "enqueued" }
        var event: [String: Any] = ["requestId": requestID, "sessionId": (enqueued ? turnSession : resp.sessionId) ?? NSNull(),
            "model": resp.model, "runId": resp.runId, "replyLen": reply.count,
            "attachmentCount": attachments.count, "durationMs": durationMs, "status": status]
        if enqueued { event["ack"] = "enqueued" }
        eventPublisher("message_out", event)
        return result
    }

    /// Prepared turns use the same retained worker as all contact doors; the latch owns only HTTP waiting.
    private func handleRetainedMessage(response: @escaping PreparedResponse, request: TurnRequest,
        principal: AgentBridgePrincipal, owner: String, claudeReplyID: String?, rawText: String,
        requestID: String, started: Date, digest: String, ackMode: String?) {
        guard let session = request.sessionID,
              NativeAgentChatSessionID.normalizedPathComponent(session) == session else {
            response(409, ["error": "missing_reply_session", "detail": "An exact conversation is required; no work was admitted."])
            return
        }
        let prefix = AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)
        let context = session.hasPrefix(prefix) ? String(session.dropFirst(prefix.count)) : session
        let taskID = "na3.\(context).\(requestID)"
        let enqueuedMode = ackMode == "enqueue" || ackMode == "enqueue_only"
        let runTurn = ackMode != "enqueue_only"
        let latch = ClaudeBridgeRuntime.WorkLatch()
        let client = chatClient()
        let tasks = self.tasks
        let binding = AgentContactBridgeInput(principal: principal, persona: request.persona,
            ownedSessionID: request.ownedSessionID, originID: claudeReplyID)
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let accepted = try await tasks.sendBridge(context: context, request: requestID, principal: principal,
                    digest: digest, binding: binding) { bindRun in
                    var prepared = request
                    var produced: ChatTurnRuntime.ChatResponse?
                    do {
                        // The exact run is retained before enqueue can append the user row.
                        try await bindRun(session, requestID)
                        prepared.pinnedRunID = requestID
                        prepared.replyRoute = ChatToolSessionContext.ReplyRoute(surface: "caller-result",
                            destinationId: principal.id, threadId: context, correlationId: requestID)
                        var ingress = prepared.turn()
                        let enqueued = try await client.enqueueUserMessage(message: prepared.message, sessionId: prepared.sessionID,
                            persona: prepared.persona, surface: prepared.surface, attachments: prepared.attachments,
                            mechanicalRow: runTurn ? nil : .transportNotice, awaitingConsumption: runTurn, turn: ingress)
                        self.eventPublisher("message_enqueued", ["requestId": requestID, "task_id": taskID,
                            "runId": enqueued.runId, "sessionId": enqueued.sessionId,
                            "textLen": request.message.count, "turn": runTurn ? "started" : "suppressed"])
                        if enqueuedMode, latch.claim() { response(200, ["status": "ok", "ack": "enqueued",
                            "requestId": requestID, "task_id": taskID, "sessionId": enqueued.sessionId,
                            "turn": runTurn ? "started" : "suppressed"]) }
                        if !runTurn {
                            await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                            return AgentContactOutcome(state: .completed, parts: [],
                                toolResult: .object(["status": .string("ok"), "ack": .string("enqueued"), "turn": .string("suppressed")]))
                        }
                        prepared = prepared.consuming(enqueued)
                        ingress.session = enqueued.sessionId
                        ingress.run = enqueued.runId
                        let admitted = try await TurnAdmission.admittedRun(turn: ingress, arrival: prepared.arrival(.saved),
                            dataRoot: self.portDataRoot) { turn in
                            let response = try await prepared.chat(on: client, holding: turn, progress: self.chatNoticeSink(requestID: requestID,
                                sessionID: session, runID: requestID))
                            return (response, turn)
                        }
                        let execution: (ChatTurnRuntime.ChatResponse, Turn)
                        switch admitted {
                        case .ran(let ran): execution = ran
                        case .steered(let steered):
                            await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                            return Self.steeredOutcome(steered)
                        }
                        let reply = execution.0
                        produced = reply
                        let result = try await self.settleMessageReply(turn: execution.1, reply, request: request, principal: principal,
                            owner: owner, claudeReplyID: claudeReplyID, replyText: rawText,
                            requestID: requestID, started: started, sessionID: session, enqueued: enqueuedMode)
                        return Self.bridgeOutcome(reply, taskID: taskID, result: result)
                    } catch {
                        await self.port.publishChatTurnCompleted(sessionID: session)
                        if let produced {
                            // A settlement error cannot discard already produced words or files.
                            let detail = "The turn returned, but bridge settlement needs repair: " + error.localizedDescription
                            RepairOwed.owe(self.portDataRoot, id: requestID, kind: .message,
                                operation: "bridge.reply.settle:" + requestID, owner: taskID,
                                words: detail, lever: "Repair the exact bridge delivery from its retained task and run; do not repeat the turn.")
                            return Self.bridgeOutcome(produced, taskID: taskID,
                                result: ["status": produced.terminalState?.rawValue ?? "incomplete", "detail": detail])
                        }
                        throw error
                    }
                }
                let task: AgentContactTask
                if accepted.state.terminal { task = accepted }
                else { task = try await tasks.settledBridge(accepted.id, owner: principal.id) }
                self.eventPublisher("message_settled", ["requestId": requestID, "task_id": task.id,
                    "sessionId": session, "state": task.state.rawValue])
                guard latch.claim() else { return }
                var result = task.toolResult?.foundationObject as? [String: Any]
                    ?? AgentContactRoutes.contactReply(task, requestID: requestID, sessionID: session, offset: 0, maxChars: 8000)
                result["requestId"] = requestID; result["sessionId"] = session; result["task_id"] = task.id
                result["reply"] = task.text
                result["runId"] = task.canonicalRunID ?? NSNull()
                result["execution_terminal"] = task.state.terminal
                result["execution_result_class"] = task.state == .completed ? "succeeded"
                    : task.state == .failed ? "failed" : task.state.terminal ? "cancelled" : "unknown"
                // contactReply's "ok" acknowledges a read, not successful work; status names the work's own outcome.
                result["status"] = task.state == .completed ? "completed" : task.state.rawValue
                if let recovery = task.replyRecovery {
                    result["retrieval_result_class"] = "failed"
                    result["detail"] = recovery.detail
                }
                response(task.state == .failed ? 409 : 200, result)
            } catch {
                self.eventPublisher("message_failed", ["requestId": requestID, "task_id": taskID,
                    "sessionId": session, "detail": error.localizedDescription])
                guard latch.claim() else { return }
                response(409, ["status": "unavailable", "requestId": requestID, "task_id": taskID,
                    "sessionId": session, "detail": error.localizedDescription + ". Inspect this task before resending."])
            }
        }
    }

    private var portDataRoot: URL { PersistenceCore.defaultDataRoot() }

    /// The agent's turn in progress read this message: its reply answers it, so this request carries no answer of its own, only where to read it.
    static func steeredOutcome(_ steered: TurnAdmission.Steered) -> AgentContactOutcome {
        let request = steered.requestID.map { " Its answer is the reply to request \($0)." } ?? ""
        return AgentContactOutcome(state: .completed, parts: [], detail: "Read by the agent's turn in progress." + request,
            toolResult: .object(["status": .string("steered"), "turnId": .string(steered.turnID), "runId": .string(steered.runID),
                "requestId": steered.requestID.map(JSONValue.string) ?? .null]))
    }

    static func bridgeOutcome(_ response: ChatTurnRuntime.ChatResponse, taskID: String,
                                      result: [String: Any]) -> AgentContactOutcome {
        let state: AgentContactTaskState
        switch response.terminalState {
        case .completed?: state = .completed
        case .stopped?: state = .canceled
        case .waiting?: state = .inputRequired
        case .interrupted?, .failed?: state = .failed
        case nil: state = .working
        }
        let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
        var parts: [AgentContactPart] = answer.isEmpty ? [] : [.text(answer)]
        var failures: [String] = []
        for (index, attachment) in (response.attachments ?? []).enumerated() {
            do {
                let part = try AgentContactPart.output(attachment, taskID: taskID)
                guard try JSONSerialization.data(withJSONObject: (parts + [part]).map(\.wire03)).count <= AgentContactPart.maximumOutputBytes else {
                    throw AgentContactFailure(code: -32603, message: "Produced files exceed the reply limit")
                }
                parts.append(part)
            }
            catch { failures.append("attachment[\(index)]: \(error.localizedDescription)") }
        }
        let recovery = failures.isEmpty ? nil : AgentContactReplyRecovery(source: "chat/messages/\(response.sessionId ?? "").jsonl",
            detail: failures.joined(separator: "; ") + ". Repair the produced files and read this task again; do not repeat the turn.")
        var metadata = result
        // Retain onward-delivery verdicts so later reads see the same evidence.
        for key in ["reply", "runId", "sessionId", "execution_result_class", "execution_terminal"] { metadata.removeValue(forKey: key) }
        let detail = response.statusDetail ?? (response.terminalState == nil
            ? "The turn returned without a terminal execution observation. Read its retained run; do not repeat the work." : nil)
        return AgentContactOutcome(state: state, parts: parts, detail: detail,
            replyRecovery: recovery, toolResult: JSONValue(fromFoundation: metadata))
    }

    /// Serialize reply receipts; failure preserves the turn and owes exact receipt repair.

    /// Return local attachment handles without embedding base64 in HTTP or durable receipts. Validate image files once and retain a specific reason for every
    /// skipped image; only allowlisted senders may name themselves.
    static let scriptSenders: Set<String> = ["install_app.sh"]

    static func withImageSkipNote(_ text: String, _ skips: [String]) -> String {
        guard !skips.isEmpty else { return text }
        let noun = skips.count == 1 ? "image" : "images"
        // Attachment notices name the failure and how the sender can recover.
        return text + "\n\n[\(skips.count) \(noun) not attached: " + skips.joined(separator: "; ")
            + ". The sender can resend the file\(skips.count == 1 ? "" : "s").]"
    }

    /// One descriptor read supplies both the pixels and any skip explanation. Nonblocking open plus fstat rejects FIFOs/devices before any read; the byte cap
    /// remains enforced if a regular file grows after fstat.
    static func prepareBridgeImages(_ paths: [String]) -> (attachments: [ChatTurnRuntime.MultimodalAttachment], skips: [String]) {
        let mimes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"]
        var out: [ChatTurnRuntime.MultimodalAttachment] = []
        var skips: [String] = []
        let limit = 8 * 1024 * 1024
        func read(_ url: URL) -> (Data?, String?) {
            let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return (nil, errno == ENOENT ? "not found" : "could not be opened") }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return (nil, "not a readable regular file") }
            guard info.st_size <= limit else { return (nil, "over 8 MB") }
            var data = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                guard !Task.isCancelled else { return (nil, "attachment read cancelled") }
                let count = Darwin.read(fd, &chunk, min(chunk.count, limit - data.count + 1))
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { return (nil, "could not be read") }
                if count == 0 { break }
                guard count <= limit - data.count else { return (nil, "over 8 MB") }
                data.append(contentsOf: chunk.prefix(count))
            }
            return data.isEmpty ? (nil, "empty file (still being written?)") : (data, nil)
        }
        for (index, raw) in paths.enumerated() {
            let url = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            let name = url.lastPathComponent
            if index >= 4 { skips.append("\(name): past the four-image limit"); continue }
            guard let mime = mimes[url.pathExtension.lowercased()] else { skips.append("\(name): not an image type the bridge takes"); continue }
            let result = read(url)
            guard let data = result.0 else { skips.append("\(name): \(result.1 ?? "could not be read")"); continue }
            out.append(ChatTurnRuntime.MultimodalAttachment(
                type: "image", base64: data.base64EncodedString(), mime: mime,
                name: url.lastPathComponent, byteSize: data.count, path: url.path
            ))
        }
        return (out, skips)
    }

    static func bridgeAttachmentPayload(
        _ attachments: [ChatTurnRuntime.MultimodalAttachment]?
    ) -> [[String: Any]] {
        (attachments ?? []).map { attachment in
            [
                "id": attachment.id,
                "type": attachment.type,
                "mime": attachment.mime,
                "name": attachment.name ?? NSNull(),
                "byteSize": attachment.byteSize,
                "path": attachment.path ?? NSNull(),
            ]
        }
    }

    /// Answers must name the exact send owed to this contact, regardless of door.
    static func validClaudeReplyID(_ messageID: String, owner: String) throws -> String? {
        let root = PersistenceCore.defaultDataRoot()
        let identity = try AgentContactIdentity(dataRoot: root)
        let records = try AgentConversationStore(dataRoot: root).records()
        guard !messageID.isEmpty, messageID.utf8.count <= 128,
              records.contains(where: { identity.canonical($0.agent) == owner && $0.readInput?["message_id"] == .string(messageID) }) else { return nil }
        return messageID
    }

    /// A message naming neither a send nor a conversation answers nothing.
    static func claudeReplyID(_ json: [String: Any], owner: String) throws -> String? {
        if let named = (json["reply_to"] ?? json["in_reply_to"]) as? String, !named.isEmpty {
            return try validClaudeReplyID(named, owner: owner)
        }
        guard let conversation = json["conversation_id"] as? String, !conversation.isEmpty, conversation.utf8.count <= 512
        else { return nil }
        return try AgentConversationStore(dataRoot: PersistenceCore.defaultDataRoot())
            .waitingMessage(agent: owner, conversationID: conversation).flatMap { try validClaudeReplyID($0, owner: owner) }
    }

    /// Persist the answer before settling its receipt and exchange; copies retain its attested speaker and steering stamp.
    static func recordClaudeReply(to messageID: String, text: String, sessionId: String?, owner: String,
                                   principal: AgentBridgePrincipal, request: TurnRequest) throws {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let steeredBy: [String] = if case .some(.some(let origin)) = request.origin { origin.peerSources ?? [] } else { [] }
        _ = try AgentConversationStore(dataRoot: dataRoot)
            .settleReply(agent: owner, messageID: messageID, text: text, landedIn: sessionId,
                         from: principal.peerID.map { "peer:" + $0 } ?? "another agent", steeredBy: steeredBy)
    }

    /// Live and restart-recovered builder turns settle through the same owner.
    static func settleContactReply(turn: Turn, _ response: ChatTurnRuntime.ChatResponse, request: TurnRequest,
        principal: AgentBridgePrincipal, owner: String, replyID: String?, replyText: String,
        session: String?, client: SwiftNativeChatOrchestrationClient,
        sender: any AgentBridgeCompletionSending) async throws {
        guard let replyID else { return }
        try recordClaudeReply(to: replyID, text: replyText, sessionId: session,
            owner: owner, principal: principal, request: request)
        try await answerAskingChat(turn: turn, replyTo: replyID, response: response, turnSession: session,
            owner: owner, client: client, sender: sender)
    }

    /// Return answers from the contact’s own session to the original asking chat.
    private static func answerAskingChat(turn: Turn, replyTo messageID: String, response: ChatTurnRuntime.ChatResponse,
        turnSession: String?, owner: String, client: SwiftNativeChatOrchestrationClient,
        sender: any AgentBridgeCompletionSending) async throws {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let identity = try AgentContactIdentity(dataRoot: dataRoot)
        let threadOwner = owner.hasPrefix("peer:") ? String(owner.dropFirst(5)) : owner
        let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
        guard let turnSession, turnSession == ContactThread.session(owner: threadOwner),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(response.attachments ?? []).isEmpty,
              let row = try AgentConversationStore(dataRoot: dataRoot).records().first(where: {
                  identity.canonical($0.agent) == owner && $0.readInput?["message_id"] == .string(messageID)
              }), row.scopeSessionID != turnSession else { return }
        let deliveryId = owner + "-reply:" + messageID
        let route = AgentBridgeCompletionRoute(asking: row, turnSessionId: turnSession)
        let digest = SHA256.hash(data: Data(answer.utf8)).map { String(format: "%02x", $0) }.joined()
        let lifecycle = CodexCompletionLifecycle.shared
        // Deduplicate resent answers so the asking chat receives one reply.
        guard try await lifecycle.claim(deliveryId: deliveryId, requestDigest: digest, sessionId: turnSession,
                                         responseRunId: response.runId, route: route) == .start else { return }
        try await lifecycle.cacheResponse(response, deliveryId: deliveryId, requestDigest: digest)
        let delivery = await AgentBridgeCompletionRouter.deliverAnswer(turn: turn, deliveryId: deliveryId, requestDigest: digest,
            text: answer, attachments: response.attachments ?? [],
            route: route, client: client,
            sender: sender, lifecycle: lifecycle, notifyRequestedResult: false)
        if delivery.status != "completed" {
            throw AgentContactFailure(code: -32603, message: "Answer to \(messageID) is \(delivery.status): \(delivery.reason ?? "delivery not confirmed")")
        }
    }

    /// Publish status notices before the terminal event; requestId joins early notices to canonical run/session IDs. Forward status only, never approval
    /// actions or assistant/tool content.
    func chatNoticeSink(
        requestID: String,
        sessionID: String?,
        runID: String? = nil
    ) -> TurnEventSink {
        { [weak self] event in
            guard case .notice(let kind, let text) = event else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Redact BEFORE clipping so a boundary cannot expose a partial key.
            self?.eventPublisher("message_notice", [
                "requestId": requestID,
                "sessionId": sessionID ?? NSNull(),
                "runId": runID ?? NSNull(),
                "noticeKind": String(NativeAgentSecretRedactor.redactText(kind).prefix(80)),
                "text": String(NativeAgentSecretRedactor.redactText(trimmed).prefix(1_000)),
            ])
        }
    }

}

extension CodexCompletionLifecycle {
    public static let shared = CodexCompletionLifecycle(
        receiptURL: ClaudeBridgeMessageRuntime.messageReplyURL(),
        ownerInstanceId: processOwnerInstanceId
    )
}

extension TurnAdmission {
    /// Register the run for Stop before session admission waits; repeated acceptance of the same traced run is idempotent.
    static func admittedRun<T>(turn: Turn, arrival: TurnArrival, dataRoot: URL, waitForCapacity: Bool = false,
                               isolation: isolated (any Actor)? = #isolation,
                               operation: (Turn) async throws -> T) async throws -> Admitted<T> {
        let flag = turn.session.map { session in
            ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: session, runId: turn.run, turnId: turn.id) }
        defer { flag.map(ChatCancelFlag.finish) }
        return try await TurnTraceContext.$turnId.withValue(turn.id) {
            try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: turn.session, arrival: arrival, runID: turn.run,
                waitForCapacity: waitForCapacity, turn: turn) { admitted in
                try await operation(admitted)
            }
        }
    }
}
