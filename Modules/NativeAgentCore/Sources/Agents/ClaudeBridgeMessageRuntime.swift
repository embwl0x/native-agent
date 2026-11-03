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
// Blueprint: | `ClaudeBridgeMessageRuntime.swift` | Prepared builder turns run in AgentContactTasks with exact session/run bindings; HTTP deadlines end only the wait; canonical tasks retain output and transport metadata before the final reply; historical receipt reads remain for retained evidence; inline replies settle their existing conversation without a new turn |

/// App selection, transport publication and existing delivery adapters used by
/// the Core conversation owner. Authentication happens before this boundary.
public protocol ClaudeBridgeMessagePort: Sendable {
    func activeSessionID(dataRoot: URL) throws -> String?
    func activePersona(dataRoot: URL) throws -> String?
    func chatClient() -> SwiftNativeChatOrchestrationClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func publishChatTurnCompleted(sessionID: String?) async
}

/// Routing and formatting for the bridge conversation. AgentContactTasks owns
/// admission, the accepted worker and durable return receipt.
public final class ClaudeBridgeMessageRuntime: @unchecked Sendable {
    public typealias Response = @Sendable (Int, [String: Any]) -> Void
    /// HTTP response deadline; accepted turns continue through durable settlement.
    public static let messageWorkDeadlineSeconds: Int = 600
    /// Enqueue acknowledgement deadline; expiry ends only the HTTP wait.
    public static let enqueueAckDeadlineSeconds: Int = 30
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

    /// Everything the inbound peer lanes know about ONE peer request: who the
    /// caller proved it is (never the shared bridge bearer alone), which
    /// protocol it arrived on, and a digest of the exact bytes. See `AgentBridgePrincipal` and
    /// `AgentPeerReplayClaimStore`.
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

    /// Generic mounted-surface identity, before enqueue/persistence. A supplied
    /// identity is continued exactly or rejected; it never falls back to the
    /// user's selected chat. The acknowledgement retains newly created IDs.
    /// A requested id must carry the authenticated `owner`'s peer prefix.
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

    public func handleMessage(response: @escaping Response, body: Data, defaultSender: String, principal: AgentBridgePrincipal) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            response(400, ["error": "invalid_json"])
            return
        }
        guard let rawText = json["text"] as? String, !rawText.isEmpty else {
            response(400, ["error": "missing_text"])
            return
        }
        let isCodexCompletion = json["completion"] is [String: Any]
        let dataRoot = PersistenceCore.defaultDataRoot()
        if isCodexCompletion {
            do {
                guard try DataRootLife.isCurrent(json["lifeID"] as? String, in: dataRoot) else {
                    response(409, ["status": "stopped", "reason": DataRootLife.stoppedReason]); return
                }
            } catch { response(503, ["error": "life_id_unavailable", "detail": error.localizedDescription]); return }
        }
        let owner: String
        do { owner = try AgentContactIdentity(dataRoot: dataRoot).canonical("peer:" + principal.id) }
        catch { response(503, ["error": "contact_identity_unavailable", "detail": error.localizedDescription]); return }
        let threadOwner = owner.hasPrefix("peer:") ? String(owner.dropFirst(5)) : owner
        let requestedSessionId = json["sessionId"] as? String
        // Attach up to four local images, 8 MB each; report skipped images in the message.
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
        // Peers default to their own conversation; scripts use the active chat; completions require explicit routing.
        let selectedSession: String?
        do {
            if isCodexCompletion || requestedSessionId != nil { selectedSession = nil }
            else if sender == defaultSender { selectedSession = ContactThread.session(owner: threadOwner) }
            else { selectedSession = try port.activeSessionID(dataRoot: dataRoot) }
        } catch {
            response(503, ["error": "active_session_unavailable", "detail": "The selected chat could not be read: \(error.localizedDescription). Repair the session index before retrying."]); return
        }
        let sessionId = Self.bridgeMessageSessionID(
            requested: requestedSessionId,
            active: selectedSession
        )
        if !isCodexCompletion, sessionId == nil {
            response(409, [
                "error": "no_active_chat_session",
                "detail": "Create or select a chat in NativeAgent, then retry.",
            ])
            return
        }
        let deliveryId: String? = {
            guard let value = json["deliveryId"] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
            return trimmed
        }()
        if isCodexCompletion && deliveryId == nil {
            response(400, ["error": "codex_completion_delivery_id_missing"])
            return
        }
        let completionRequestDigest = isCodexCompletion
            ? Self.codexCompletionRequestDigest(json, attachments: attachments)
            : nil
        if isCodexCompletion && completionRequestDigest == nil {
            response(400, ["error": "codex_completion_digest_failed"])
            return
        }
        let completionRoute: AgentBridgeCompletionRoute? = {
            guard isCodexCompletion else { return nil }
            return AgentBridgeCompletionRoute(
                origin: json["origin"] as? [String: Any],
                sessionId: sessionId
            )
        }()
        let claudeReplyID: String?
        do { claudeReplyID = try Self.claudeReplyID(json, owner: owner) }
        catch { response(503, ["error": "reply_identity_unavailable", "detail": error.localizedDescription]); return }
        if let claudeReplyID, attachments.isEmpty {
            let from = principal.peerID.map { "peer:" + $0 } ?? "another agent"
            do {
                if try AgentConversationStore(dataRoot: dataRoot).offerBridgeReplyToInlineWait(
                    agent: owner, messageID: claudeReplyID, text: rawText, from: from, steeredBy: [from],
                    recordReply: {
                        try Self.recordClaudeReplyReceipt(to: claudeReplyID, text: rawText, sessionId: sessionId, owner: owner)
                    }) {
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
            response(503, ["error": "active_persona_unavailable", "detail": "The selected persona could not be read: \(error.localizedDescription). Repair the persona selection before retrying."]); return
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
        // Publish: bridge received an inbound message (me → her).
        eventPublisher("message_in", [
            "requestId": requestID,
            "sender": sender,
            "textLen": text.count,
            "sessionId": sessionId ?? NSNull(),
        ])
        let ackMode = (json["ackMode"] as? String)?.lowercased()
        let requestIdentity: String
        if let deliveryId {
            let hash = CausalTransitionEvidence.opaqueIdentity(deliveryId)
            let value = Array(hash)
            requestIdentity = String(value[0..<8]) + "-" + String(value[8..<12]) + "-" + String(value[12..<16])
                + "-" + String(value[16..<20]) + "-" + String(value[20..<32])
        } else if let supplied = json["request_id"] {
            guard let value = supplied as? String, UUID(uuidString: value) != nil else {
                response(400, ["error": "invalid_request_id"]); return
            }
            requestIdentity = value
        } else { requestIdentity = requestID }
        handleRetainedMessage(response: response, request: baseRequest, principal: principal, owner: owner,
            claudeReplyID: claudeReplyID, rawText: rawText, requestID: requestIdentity,
            started: started, digest: AgentPeerReplayClaimStore.digest(body), ackMode: ackMode, source: defaultSender,
            completionRoute: completionRoute, deliveryID: deliveryId, completionDigest: completionRequestDigest)
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

    /// Read the existing receipt stream, without a second store or an action
    /// replay. Bounded scan and bounded rows keep recovery independent of log
    /// size. A damaged/incomplete scope cannot establish absence or uniqueness.
    /// With `principal`, only a receipt recorded for that caller is a match;
    /// another caller's receipt for the same ids reads as no receipt.
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
        // These retained rows predate the explicit contract. Their combined
        // delivery words are evidence, never proof of execution or settlement.
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

    /// Both HTTP modes settle completed replies here, independently of acknowledgement ownership.
    private func settleMessageReply(_ resp: ChatTurnRuntime.ChatResponse, request: TurnRequest,
        principal: AgentBridgePrincipal, owner: String, claudeReplyID: String?, replyText: String,
        requestID: String, started: Date, sessionID: String?, enqueued: Bool = false,
        callerResultIsTool: Bool = false, responseCached: Bool = false, wasCached: Bool = false,
        completionRoute: AgentBridgeCompletionRoute? = nil, deliveryID: String? = nil,
        completionDigest: String? = nil) async throws -> [String: Any] {
        let turnSession = resp.sessionId ?? sessionID
        if !callerResultIsTool { await port.publishChatTurnCompleted(sessionID: turnSession) }
        try await Self.settleContactReply(resp, request: request, principal: principal, owner: owner,
            replyID: claudeReplyID, replyText: replyText, session: turnSession, client: chatClient(),
            sender: port.completionSender(dataRoot: portDataRoot))
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let reply = ChatResponse.answerOnly(resp.output, workingCommentaryCharacters: resp.workingCommentaryCharacters)
        let hasText = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let attachments = Self.bridgeAttachmentPayload(resp.attachments)
        let completionDelivery: AgentBridgeCompletionDelivery?
        if let completionRoute, let deliveryID, let completionDigest,
           hasText || !(resp.attachments ?? []).isEmpty {
            completionDelivery = await AgentBridgeCompletionRouter.deliver(deliveryId: deliveryID,
                requestDigest: completionDigest, text: reply, attachments: resp.attachments ?? [],
                route: completionRoute, sender: port.completionSender(dataRoot: PersistenceCore.defaultDataRoot()),
                lifecycle: CodexCompletionLifecycle.shared)
        } else { completionDelivery = nil }
        let status = resp.terminalState?.rawValue ?? "incomplete"
        var result = Self.messageReplyRecord(["status": status,
            "sessionId": (enqueued ? turnSession : resp.sessionId) ?? NSNull(),
            "model": resp.model, "runId": resp.runId, "durationMs": durationMs,
            "reply": reply, "attachments": attachments], requestID: requestID)
        if enqueued { result["ack"] = "enqueued" }
        else {
            result["responseCached"] = responseCached
            result["servedFromCache"] = wasCached
            // Canonical assistant persistence precedes any external notification.
            result["replyPersisted"] = responseCached && !callerResultIsTool && (hasText || !attachments.isEmpty)
        }
        if let deliveryID { result["deliveryId"] = deliveryID }
        if let completionDelivery { result["completionDelivery"] = completionDelivery.jsonObject }
        var event: [String: Any] = ["requestId": requestID, "sessionId": (enqueued ? turnSession : resp.sessionId) ?? NSNull(),
            "model": resp.model, "runId": resp.runId, "replyLen": reply.count,
            "attachmentCount": attachments.count, "durationMs": durationMs, "status": status]
        if enqueued { event["ack"] = "enqueued" }
        else {
            event["completionDeliveryStatus"] = completionDelivery?.status ?? NSNull()
            event["deliveryId"] = deliveryID ?? NSNull()
            event["servedFromCache"] = wasCached
        }
        eventPublisher("message_out", event)
        return result
    }

    /// Prepared bridge turns use the same retained task and worker as every
    /// contact door. The response latch controls only the HTTP wait.
    private func handleRetainedMessage(response: @escaping Response, request: TurnRequest,
        principal: AgentBridgePrincipal, owner: String, claudeReplyID: String?, rawText: String,
        requestID: String, started: Date, digest: String, ackMode: String?, source: String,
        completionRoute: AgentBridgeCompletionRoute?, deliveryID: String?, completionDigest: String?) {
        guard let session = request.sessionID,
              NativeAgentChatSessionID.normalizedPathComponent(session) == session else {
            response(409, ["error": "missing_reply_session", "detail": "An exact conversation is required; no work was admitted."])
            return
        }
        let prefix = AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)
        let context = session.hasPrefix(prefix) ? String(session.dropFirst(prefix.count)) : session
        let taskID = "na3.\(context).\(requestID)"
        let enqueuedMode = deliveryID == nil && (ackMode == "enqueue" || ackMode == "enqueue_only")
        let runTurn = ackMode != "enqueue_only"
        let latch = ClaudeBridgeRuntime.WorkLatch()
        let client = chatClient()
        let tasks = self.tasks
        let binding = deliveryID == nil ? AgentContactBridgeInput(principal: principal, persona: request.persona,
            ownedSessionID: request.ownedSessionID, originID: claudeReplyID) : nil
        Task.detached(priority: .userInitiated) { [self] in
            var completionStarted = false
            var canonicalWorkerAdmitted = false
            do {
                let completionAdmission: CodexCompletionLifecycle.ClaimAdmission?
                if let deliveryID, let completionDigest {
                    completionAdmission = try await CodexCompletionLifecycle.shared.claimAdmission(deliveryId: deliveryID,
                        requestDigest: completionDigest, sessionId: session,
                        responseRunId: CausalTransitionEvidence.opaqueIdentity(deliveryID),
                        route: completionRoute, principal: principal.id, source: source)
                } else { completionAdmission = nil }
                let completionDecision = completionAdmission?.decision
                switch completionDecision {
                case .inProgress?:
                    if latch.claim() { response(202, ["status": "completion_in_progress", "deliveryId": deliveryID ?? NSNull(),
                        "requestId": requestID, "task_id": taskID, "execution_result_class": "unknown", "execution_terminal": false]) }
                    return
                case .outcomeUnknown?:
                    if latch.claim() { response(409, ["status": "outcome_unknown", "deliveryId": deliveryID ?? NSNull(),
                        "requestId": requestID, "task_id": taskID, "execution_result_class": "unknown",
                        "detail": "The completion owner cannot yet establish its outcome. Repair the retained run; do not repeat the work."]) }
                    return
                case .conflict?:
                    if latch.claim() { response(409, ["status": "conflict", "error": "delivery_id_reused_for_different_completion"]) }
                    return
                case .settled(let delivery)?:
                    var value: [String: Any] = ["status": "completion_already_settled", "deliveryId": deliveryID ?? NSNull(),
                        "responseCached": false, "servedFromCache": true, "execution_result_class": "unknown"]
                    if let delivery { value["completionDelivery"] = delivery.jsonObject }
                    if latch.claim() { response(200, value) }
                    return
                case .cached(_)?, .start?, nil: break
                }
                let ownsCompletionStart = completionDecision == .some(.start)
                completionStarted = ownsCompletionStart
                let accepted = try await tasks.sendBridge(context: context, request: requestID, principal: principal,
                    digest: digest, binding: binding, completionAdmission: completionAdmission) { bindRun in
                    var prepared = request
                    let lifecycleClaimed = ownsCompletionStart
                    var responseCached = false
                    var executionBegan = false
                    var produced: ChatTurnRuntime.ChatResponse?
                    do {
                        let reply: ChatTurnRuntime.ChatResponse
                        var wasCached = false
                        let callerResultIsTool: Bool
                        if let completionRoute, completionRoute.surface == "caller-result" {
                            callerResultIsTool = try await tasks.callerResultTarget(completionRoute).canonicalRunID == nil
                        } else { callerResultIsTool = false }
                        if let deliveryID, let completionDigest {
                            let run = CausalTransitionEvidence.opaqueIdentity(deliveryID)
                            guard let completionDecision else { throw CodexCompletionLifecycle.LifecycleError.claimMissing }
                            switch completionDecision {
                            case .cached(let cached):
                                reply = cached; wasCached = true; responseCached = true
                                try await bindRun(cached.sessionId ?? session, cached.runId)
                            case .start:
                                try await bindRun(session, run)
                                prepared.pinnedRunID = run
                                prepared.replyRoute = (completionRoute?.chatToolReplyRoute).map { Optional($0) }
                                prepared.codexCompletion = CodexCompletionTranscriptBinding(deliveryId: deliveryID,
                                    requestDigest: completionDigest, model: "", reasoningEffort: nil)
                                if callerResultIsTool {
                                    reply = .init(runId: run, model: "", output: rawText, sessionId: session,
                                        attachments: request.attachments, providerCallCount: 0, terminalState: .completed)
                                } else {
                                    reply = try await TurnAdmission.admittedRun(dataRoot: self.portDataRoot,
                                        sessionID: session, runID: run) {
                                        executionBegan = true
                                        return try await prepared.chat(on: client, progress: self.chatNoticeSink(requestID: requestID, sessionID: session, runID: run))
                                    }
                                }
                                produced = reply
                                try await CodexCompletionLifecycle.shared.cacheResponse(reply, deliveryId: deliveryID, requestDigest: completionDigest)
                                responseCached = true
                            case .inProgress, .outcomeUnknown, .conflict, .settled:
                                throw CodexCompletionLifecycle.LifecycleError.claimMissing
                            }
                        } else {
                            // The exact run is retained before enqueue can append the user row.
                            try await bindRun(session, requestID)
                            prepared.pinnedRunID = requestID
                            prepared.replyRoute = ChatToolSessionContext.ReplyRoute(surface: "caller-result",
                                destinationId: principal.id, threadId: context, correlationId: requestID)
                            let enqueued = try await prepared.enqueue(on: client,
                                    mechanicalRow: runTurn ? nil : .transportNotice, awaitingConsumption: runTurn)
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
                            reply = try await TurnAdmission.admittedRun(dataRoot: self.portDataRoot,
                                sessionID: session, runID: requestID) {
                                try await prepared.chat(on: client, progress: self.chatNoticeSink(requestID: requestID, sessionID: session, runID: requestID))
                            }
                        }
                        produced = reply
                        let result = try await self.settleMessageReply(reply, request: request, principal: principal,
                            owner: owner, claudeReplyID: claudeReplyID, replyText: rawText,
                            requestID: requestID, started: started, sessionID: session, enqueued: enqueuedMode,
                            callerResultIsTool: callerResultIsTool, responseCached: responseCached, wasCached: wasCached,
                            completionRoute: completionRoute, deliveryID: deliveryID, completionDigest: completionDigest)
                        return Self.bridgeOutcome(reply, taskID: taskID, result: result)
                    } catch {
                        if lifecycleClaimed, !responseCached, let deliveryID, let completionDigest {
                            do {
                                if produced == nil, !executionBegan {
                                    try await CodexCompletionLifecycle.shared.markNotStarted(deliveryId: deliveryID, requestDigest: completionDigest)
                                } else {
                                    try await CodexCompletionLifecycle.shared.markOutcomeUnknown(deliveryId: deliveryID,
                                        requestDigest: completionDigest, detail: error.localizedDescription)
                                }
                            } catch {
                                RepairOwed.owe(self.portDataRoot, id: deliveryID, kind: .message,
                                    operation: "bridge.completion.settle:" + deliveryID, owner: taskID,
                                    words: error.localizedDescription, lever: "Repair this exact completion receipt from its retained run; do not repeat the turn.")
                            }
                        }
                        await self.port.publishChatTurnCompleted(sessionID: session)
                        if let produced {
                            // A routing/cache error cannot discard already produced words or files.
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
                canonicalWorkerAdmitted = true
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
                if let deliveryID, let completionDigest {
                    result.removeValue(forKey: "completionDelivery")
                    // A completion that was owed always answers with its verdict: a missing or
                    // unreadable one is outcome_unknown, never silence the caller reads as delivered.
                    do {
                        if let delivery = try await CodexCompletionLifecycle.shared.savedDelivery(deliveryId: deliveryID, requestDigest: completionDigest) {
                            result["completionDelivery"] = delivery.jsonObject
                        } else {
                            result["completionDelivery"] = ["status": "outcome_unknown",
                                "detail": "No completion delivery record exists for this owed completion."]
                        }
                    } catch {
                        result["retrieval_result_class"] = "failed"
                        result["detail"] = "The turn's output is retained, but its current completion delivery could not be read: " + error.localizedDescription
                        result["completionDelivery"] = ["status": "outcome_unknown",
                            "detail": "The completion delivery record could not be read: " + error.localizedDescription]
                    }
                }
                // contactReply's "ok" acknowledges a read, not successful work.
                // This door's completion caller uses status as delivery evidence.
                result["status"] = task.state == .completed ? "completed" : task.state.rawValue
                if let recovery = task.replyRecovery {
                    result["retrieval_result_class"] = "failed"
                    result["detail"] = recovery.detail
                }
                response(task.state == .failed ? 409 : 200, result)
            } catch {
                if completionStarted, !canonicalWorkerAdmitted, let deliveryID, let completionDigest {
                    do {
                        if error is AgentContactBridgeClaimConflict {
                            try await CodexCompletionLifecycle.shared.markOutcomeUnknown(deliveryId: deliveryID,
                                requestDigest: completionDigest, detail: error.localizedDescription)
                        } else {
                            try await CodexCompletionLifecycle.shared.markNotStarted(deliveryId: deliveryID, requestDigest: completionDigest)
                        }
                    }
                    catch {
                        RepairOwed.owe(self.portDataRoot, id: deliveryID, kind: .message,
                            operation: "bridge.completion.admit:" + deliveryID, owner: taskID,
                            words: error.localizedDescription, lever: "Repair this exact unstarted completion claim; do not repeat a started turn.")
                    }
                }
                self.eventPublisher("message_failed", ["requestId": requestID, "task_id": taskID,
                    "sessionId": session, "detail": error.localizedDescription])
                guard latch.claim() else { return }
                response(409, ["status": "unavailable", "requestId": requestID, "task_id": taskID,
                    "sessionId": session, "detail": error.localizedDescription + ". Inspect this task before resending."])
            }
        }
        latch.arm(afterSeconds: enqueuedMode ? Self.enqueueAckDeadlineSeconds : Self.messageWorkDeadlineSeconds) { [self] in
            guard latch.claim() else { return }
            self.eventPublisher("message_deadline_released", ["requestId": requestID, "task_id": taskID, "sessionId": session])
            response(202, ["status": "still_working", "requestId": requestID, "task_id": taskID, "sessionId": session,
                "detail": "Only the HTTP wait ended. Admission and execution remain owned by this retained task; do not resend the message."])
        }
    }

    private var portDataRoot: URL { PersistenceCore.defaultDataRoot() }

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
        // The onward-delivery verdict stays with the retained reply, so a later read has it.
        for key in ["reply", "runId", "sessionId", "execution_result_class", "execution_terminal"] { metadata.removeValue(forKey: key) }
        let detail = response.statusDetail ?? (response.terminalState == nil
            ? "The turn returned without a terminal execution observation. Read its retained run; do not repeat the work." : nil)
        return AgentContactOutcome(state: state, parts: parts, detail: detail,
            replyRecovery: recovery, toolResult: JSONValue(fromFoundation: metadata))
    }

    /// Serialize reply receipts; failure preserves the turn and owes exact receipt repair.
    private static let messageReplyLock = NSLock()

    /// Return attachment metadata to a local bridge caller without embedding
    /// base64 image bytes in the HTTP response or durable reply JSONL. Generated
    /// image attachments are already constrained to data/generated_images by
    /// ChatGeneratedImageArtifacts; the local path is the useful bridge handle.
    /// Local image files named by a bridge message, as chat attachments.
    /// One reason per image the bridge could not attach: a type it does not
    /// take, a file it could not read, an empty file, or one over 8 MB.
    /// Non-human senders allowed to name themselves in a bridge message.
    static let scriptSenders: Set<String> = ["install_app.sh"]

    static func withImageSkipNote(_ text: String, _ skips: [String]) -> String {
        guard !skips.isEmpty else { return text }
        let noun = skips.count == 1 ? "image" : "images"
        // Attachment notices name the failure and how the sender can recover.
        return text + "\n\n[\(skips.count) \(noun) not attached: " + skips.joined(separator: "; ") + ". The sender can resend the file\(skips.count == 1 ? "" : "s").]"
    }

    /// One descriptor read supplies both the pixels and any skip explanation.
    /// Nonblocking open plus fstat rejects FIFOs/devices before any read; the
    /// byte cap remains enforced if a regular file grows after fstat.
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

    static func codexCompletionRequestDigest(_ json: [String: Any], attachments: [ChatTurnRuntime.MultimodalAttachment]) -> String? {
        var canonical: [String: Any] = [:]
        for key in ["text", "sessionId", "origin", "completion", "image_paths"] {
            if let value = json[key] { canonical[key] = value }
        }
        var imageDigests: [String] = []
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.base64) else { return nil }
            imageDigests.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        if !imageDigests.isEmpty { canonical["imageDigests"] = imageDigests }
        guard JSONSerialization.isValidJSONObject(canonical),
              let data = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An answer names an exact send owed to this who, through any of its doors.
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

    /// After the reply is durably in the chat: the receipt the delegation
    /// projection joins, and the answered send's conversation record settles.
    /// The answer's own row carries its door and steering (the stamp the
    /// request wrote); any copy of it carries the same, never the send's owner.
    static func recordClaudeReply(to messageID: String, text: String, sessionId: String?, owner: String,
                                   principal: AgentBridgePrincipal, request: TurnRequest) throws {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let steeredBy: [String] = if case .some(.some(let origin)) = request.origin { origin.peerSources ?? [] } else { [] }
        try recordClaudeReplyReceipt(to: messageID, text: text, sessionId: sessionId, owner: owner)
        _ = try AgentConversationStore(dataRoot: dataRoot)
            .settleReply(agent: owner, messageID: messageID, text: text, landedIn: sessionId,
                         from: principal.peerID.map { "peer:" + $0 } ?? "another agent", steeredBy: steeredBy)
    }

    /// Both inline and turn-delivered answers use this one receipt writer.
    /// Retrying a handoff after its exchange save failed must not append twice.
    private static func recordClaudeReplyReceipt(to messageID: String, text: String, sessionId: String?, owner: String) throws {
        let dataRoot = PersistenceCore.defaultDataRoot()
        guard try AgentContactIdentity(dataRoot: dataRoot).aliases["claude"] == owner else { return }
        let dir = messageReplyURL().deletingLastPathComponent()
        // The answer as every job retains it, so an exact read returns it, not a preview.
        let row: [String: Any] = [
            "messageId": messageID, "sessionId": sessionId ?? NSNull(),
            "replyText": String(text.prefix(6000)), "replyTruncated": text.count > 6000,
            "createdAt": NativeTimestampFormat.plainZulu(Date()),
        ]
        var line = try JSONSerialization.data(withJSONObject: row)
        line.append(0x0A)
        let file = dir.appendingPathComponent("claude-replies.jsonl")
        messageReplyLock.lock()
        defer { messageReplyLock.unlock() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file)
            guard bytes.isEmpty || bytes.last == 0x0A else { throw CocoaError(.fileReadCorruptFile) }
            let matches = try bytes.split(separator: 0x0A).compactMap { line -> [String: Any]? in
                guard let saved = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return saved["messageId"] as? String == messageID ? saved : nil
            }
            if let saved = matches.last,
               saved["replyText"] as? String == row["replyText"] as? String,
               saved["replyTruncated"] as? Bool == row["replyTruncated"] as? Bool {
                return
            }
        }
        try SwiftNativePersistenceCore.appendOwnedBytes(line, to: file, durable: true)
        _ = try enforceJSONLRetention(at: file, maxLines: 500, trimWhenBytesExceed: 1_048_576)
    }

    /// Live and restart-recovered builder turns settle through the same owner.
    static func settleContactReply(_ response: ChatTurnRuntime.ChatResponse, request: TurnRequest,
        principal: AgentBridgePrincipal, owner: String, replyID: String?, replyText: String,
        session: String?, client: SwiftNativeChatOrchestrationClient,
        sender: any AgentBridgeCompletionSending) async throws {
        guard let replyID else { return }
        try recordClaudeReply(to: replyID, text: replyText, sessionId: session,
            owner: owner, principal: principal, request: request)
        try await answerAskingChat(replyTo: replyID, response: response, turnSession: session,
            owner: owner, client: client, sender: sender)
    }

    /// The answer goes back to the chat that asked, from this who's own conversation.
    private static func answerAskingChat(replyTo messageID: String, response: ChatTurnRuntime.ChatResponse,
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
        // Once per answer: a resent reply never answers the asking chat twice.
        guard try await lifecycle.claim(deliveryId: deliveryId, requestDigest: digest, sessionId: turnSession,
                                         responseRunId: response.runId, route: route) == .start else { return }
        try await lifecycle.cacheResponse(response, deliveryId: deliveryId, requestDigest: digest)
        let delivery = await AgentBridgeCompletionRouter.deliverAnswer(deliveryId: deliveryId, requestDigest: digest,
            text: answer, attachments: response.attachments ?? [],
            route: route, client: client,
            sender: sender, lifecycle: lifecycle, notifyRequestedResult: false)
        if delivery.status != "completed" {
            throw AgentContactFailure(code: -32603, message: "Answer to \(messageID) is \(delivery.status): \(delivery.reason ?? "delivery not confirmed")")
        }
    }

    static func recoverMessageReplies(lifecycle: CodexCompletionLifecycle, logURL: URL) async throws {
        for row in try await lifecycle.reconciliationRows() where row.id.hasPrefix("bridge-http.") && row.status == "owed" {
            guard let response = row.response else { continue }
            let requestID = String(row.id.dropFirst("bridge-http.".count))
            let attachments = bridgeAttachmentPayload(response.attachments)
            let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
            let status = response.terminalState?.rawValue ?? "incomplete"
            guard persistMessageReply(["at": NativeTimestampFormat.plainZulu(Date()), "status": status,
                "sessionId": response.sessionId ?? "", "runId": response.runId, "model": response.model,
                "reply": answer, "attachments": attachments, "replyPersisted": true], requestID: requestID,
                principal: row.principal, logURL: logURL) else { throw CocoaError(.fileWriteUnknown) }
            try await lifecycle.recordDelivery(AgentBridgeCompletionDelivery(status: "completed", surface: "bridge-http",
                delivery: "receipt", artifactCount: 1, attempts: 0, reason: nil), deliveryId: row.id, requestDigest: row.digest)
        }
    }

    @discardableResult
    /// `principal` is the authenticated caller the message came from; the
    /// reply is served back only to that caller.
    private static func persistMessageReply(_ payload: [String: Any], requestID: String, principal: String?,
                                            logURL: URL? = nil) -> Bool {
        messageReplyLock.lock()
        defer { messageReplyLock.unlock() }
        var payload = messageReplyRecord(payload, requestID: requestID)
        if let principal { payload["principal"] = principal }
        let file = logURL ?? messageReplyURL()
        let dir = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let written = try CredentialFileLock.withLock(file) {
                let data = try JSONSerialization.data(withJSONObject: payload)
                if FileManager.default.fileExists(atPath: file.path) {
                    let bytes = try Data(contentsOf: file)
                    guard bytes.isEmpty || bytes.last == 0x0A else { throw CocoaError(.fileReadCorruptFile) }
                    let matches = try bytes.split(separator: 0x0A).compactMap { line -> [String: Any]? in
                        guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                        return row["requestId"] as? String == requestID ? row : nil
                    }
                    guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
                    if let existing = matches.first {
                        guard existing["runId"] as? String == payload["runId"] as? String,
                              existing["sessionId"] as? String == payload["sessionId"] as? String,
                              existing["reply"] as? String == payload["reply"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                        return true
                    }
                }
                var line = data
                line.append(Data("\n".utf8))
                try SwiftNativePersistenceCore.appendOwnedBytes(line, to: file, durable: true)
                // Retain the newest 4 MiB once the feed exceeds 8 MiB.
                let dropped = try enforceJSONLRetention(
                    at: file,
                    maxBytes: 8 << 20,
                    trimToBytes: 4 << 20
                )
                if dropped > 0 {
                    nativeLog(
                        "[ClaudeBridge] message-replies cap dropped %d oldest row(s)",
                        dropped
                    )
                }
                return true
            }
            RepairOwed.settle(PersistenceCore.defaultDataRoot(), operation: "bridge.reply.receipt:" + requestID,
                evidence: .init(source: file.path, id: requestID))
            return written
        } catch {
            let detail = "Bridge reply receipt \(requestID) could not be saved: \(error.localizedDescription). The actual turn must not be repeated; repair its receipt from the retained run."
            nativeLog("[ClaudeBridge] %@", detail)
            RepairOwed.owe(PersistenceCore.defaultDataRoot(), id: requestID + ":receipt", kind: .message,
                operation: "bridge.reply.receipt:" + requestID, owner: file.path, words: detail,
                lever: "Repair the exact receipt from its retained run and completion record.")
            return false
        }
    }

    /// Awaited by chat before it returns: notices enter the existing event ring
    /// before the caller publishes its terminal event. Ordinary chat mints its
    /// run/session internally; requestId joins early notices to the terminal's
    /// canonical IDs. Enqueued turns already have both IDs. No approval action
    /// or assistant/tool content is forwarded through this status-only sink.
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
    /// The bridge's own completion lifecycle, beside its message-reply log.
    public static let shared = CodexCompletionLifecycle(
        receiptURL: ClaudeBridgeMessageRuntime.messageReplyURL(),
        ownerInstanceId: processOwnerInstanceId
    )
}

extension TurnAdmission {
    /// A bridge door's admission: the run is registered for Stop before it
    /// waits for the session, so a Stop from here on names it; the turn's own
    /// acceptance of the same run (under the same trace turn) is the same
    /// registration.
    static func admittedRun<T>(dataRoot: URL, sessionID: String?, runID: String?, waitForCapacity: Bool = false,
                               isolation: isolated (any Actor)? = #isolation,
                               operation: () async throws -> T) async throws -> T {
        let turnID = TurnTraceContext.mintTurnId()
        let flag = sessionID.flatMap { session in runID.map {
            ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: session, runId: $0, turnId: turnID) } }
        defer { flag.map(ChatCancelFlag.finish) }
        return try await TurnTraceContext.$turnId.withValue(turnID) {
            try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: sessionID, runID: runID, waitForCapacity: waitForCapacity, operation: operation)
        }
    }
}
