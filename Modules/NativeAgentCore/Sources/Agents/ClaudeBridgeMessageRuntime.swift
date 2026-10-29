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
// Blueprint: | `ClaudeBridgeMessageRuntime.swift` | Bridge message admission/delivery and the retained chat client; replies omit working commentary at the turn's recorded boundary; an exact text reply records its durable receipt before publishing an inline answer, without starting another turn; event publication is a weak callback to the HTTP runtime |

/// App selection, transport publication and existing delivery adapters used by
/// the Core conversation owner. Authentication happens before this boundary.
public protocol ClaudeBridgeMessagePort: Sendable {
    func activeSessionID(dataRoot: URL) -> String?
    func activePersona(dataRoot: URL) -> String?
    func chatClient() -> SwiftNativeChatOrchestrationClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func publishChatTurnCompleted(sessionID: String?) async
}

/// Admission, enqueue, completion and durable return receipts for the existing
/// bridge conversation. This owner has no Network connection or listener.
public final class ClaudeBridgeMessageRuntime: @unchecked Sendable {
    public typealias Response = @Sendable (Int, [String: Any]) -> Void
    /// HTTP response deadline; accepted turns continue through durable settlement.
    public static let messageWorkDeadlineSeconds: Int = 600
    /// Enqueue acknowledgement deadline; expiry cancels enqueue before turn admission.
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
        let owner = AgentContactIdentity(dataRoot: dataRoot).canonical("peer:" + principal.id)
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
        let sessionId = Self.bridgeMessageSessionID(
            requested: requestedSessionId,
            active: isCodexCompletion ? nil
                : sender == defaultSender ? ContactThread.session(owner: threadOwner)
                : port.activeSessionID(dataRoot: PersistenceCore.defaultDataRoot())
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
        let claudeReplyID = Self.claudeReplyID(json, owner: owner)
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
        let baseRequest: TurnRequest = {
            var request = principal.turnRequest(context: nil, plain: rawText, attachments: attachments, originID: claudeReplyID)
            request.sessionID = sessionId
            request.ownedSessionID = ContactThread.session(owner: threadOwner)
            request.verifiedSessionID = .some(sessionId)
            request.persona = port.activePersona(dataRoot: dataRoot)
            request.message = Self.withImageSkipNote(request.message, imageSkips)
            return request
        }()
        let text = baseRequest.message
        let client = chatClient()
        let started = Date()
        let requestID = UUID().uuidString
        // Publish: bridge received an inbound message (me → her).
        eventPublisher("message_in", [
            "requestId": requestID,
            "sender": sender,
            "textLen": text.count,
            "sessionId": sessionId ?? NSNull(),
        ])
        // Enqueue acknowledges the durable row; enqueue_only starts no turn.
        // Codex completions retain blocking claim/settled/conflict responses.
        let ackMode = (json["ackMode"] as? String)?.lowercased()
        if !isCodexCompletion, ackMode == "enqueue" || ackMode == "enqueue_only" {
            handleMessageAckOnEnqueue(
                response: response,
                client: client,
                request: baseRequest,
                principal: principal,
                claudeReplyID: claudeReplyID,
                claudeReplyText: rawText,
                requestID: requestID,
                started: started,
                runTurn: ackMode != "enqueue_only"
            )
            return
        }
        // The work task and HTTP deadline share one response latch.
        let progress = chatNoticeSink(requestID: requestID, sessionID: sessionId)
        let workLatch = ClaudeBridgeRuntime.WorkLatch()
        _ = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lifecycleClaimed = false
            var responseCached = false
            do {
                let callerResultIsTool: Bool
                if let completionRoute, completionRoute.surface == "caller-result" {
                    callerResultIsTool = try await self.tasks.callerResultTarget(completionRoute).canonicalRunID == nil
                } else {
                    callerResultIsTool = false
                }
                let resp: ChatTurnRuntime.ChatResponse
                var wasCached = false
                if let deliveryId, let completionRequestDigest {
                    let responseRunID = CausalTransitionEvidence.opaqueIdentity(deliveryId)
                    switch try await CodexCompletionLifecycle.shared.claim(
                        deliveryId: deliveryId,
                        requestDigest: completionRequestDigest,
                        sessionId: sessionId,
                        responseRunId: responseRunID,
                        route: completionRoute,
                        principal: principal.id, source: defaultSender
                    ) {
                    case .cached(let cached):
                        resp = cached
                        responseCached = true
                        wasCached = true
                    case .settled(let delivery):
                        guard workLatch.claim() else { return }
                        var object: [String: Any] = [
                            "status": "completion_already_settled",
                            "deliveryId": deliveryId,
                            "responseCached": false,
                            "servedFromCache": true,
                        ]
                        if let delivery {
                            object["completionDelivery"] = delivery.jsonObject
                        }
                        response(200, object)
                        return
                    case .start:
                        lifecycleClaimed = true
                        var request = baseRequest
                        request.replyRoute = (completionRoute?.chatToolReplyRoute).map { Optional($0) }
                        request.pinnedRunID = responseRunID
                        request.codexCompletion = CodexCompletionTranscriptBinding(
                                deliveryId: deliveryId,
                                requestDigest: completionRequestDigest,
                                // Canonical assistant persistence replaces
                                // these placeholders with executed truth.
                                model: "",
                                reasoningEffort: nil
                        )
                        let generated: ChatTurnRuntime.ChatResponse
                        if callerResultIsTool {
                            generated = .init(runId: responseRunID, model: "", output: rawText,
                                              sessionId: sessionId, attachments: attachments, providerCallCount: 0)
                        } else {
                            generated = try await TurnAdmission.admittedRun(dataRoot: PersistenceCore.defaultDataRoot(),
                                sessionID: sessionId, runID: responseRunID) {
                                try await request.chat(on: client, progress: progress)
                            }
                        }
                        // Cache the response before external delivery so retries
                        // never start another model turn.
                        try await CodexCompletionLifecycle.shared.cacheResponse(
                            generated,
                            deliveryId: deliveryId,
                            requestDigest: completionRequestDigest
                        )
                        responseCached = true
                        resp = generated
                    case .inProgress:
                        guard workLatch.claim() else { return }
                        response(202, [
                            "status": "completion_in_progress",
                            "deliveryId": deliveryId,
                        ])
                        return
                    case .outcomeUnknown:
                        guard workLatch.claim() else { return }
                        response(409, [
                            "status": "outcome_unknown",
                            "error": "completion_claim_interrupted",
                            "deliveryId": deliveryId,
                        ])
                        return
                    case .conflict:
                        guard workLatch.claim() else { return }
                        response(409, [
                            "status": "conflict",
                            "error": "delivery_id_reused_for_different_completion",
                            "deliveryId": deliveryId,
                        ])
                        return
                    }
                } else {
                    var request = baseRequest
                    request.pinnedRunID = requestID
                    request.codexCompletion = CodexCompletionTranscriptBinding(
                        deliveryId: "bridge-http." + requestID, requestDigest: requestID, model: "", reasoningEffort: nil)
                    _ = try await CodexCompletionLifecycle.shared.claim(deliveryId: "bridge-http." + requestID,
                        requestDigest: requestID, sessionId: sessionId, responseRunId: requestID, principal: principal.id)
                    resp = try await TurnAdmission.admittedRun(dataRoot: PersistenceCore.defaultDataRoot(),
                        sessionID: sessionId, runID: requestID) {
                        try await request.chat(on: client, progress: progress)
                    }
                    try await CodexCompletionLifecycle.shared.cacheResponse(resp, deliveryId: "bridge-http." + requestID, requestDigest: requestID)
                }
                let responseObject = try await self.settleMessageReply(resp, request: baseRequest,
                    principal: principal, owner: owner, claudeReplyID: claudeReplyID, replyText: rawText,
                    requestID: requestID, started: started, sessionID: sessionId,
                    callerResultIsTool: callerResultIsTool, responseCached: responseCached, wasCached: wasCached,
                    completionRoute: completionRoute, deliveryID: deliveryId, completionDigest: completionRequestDigest)
                // Settlement runs even when the HTTP deadline has already answered.
                guard workLatch.claim() else { return }
                response(200, responseObject)
            } catch is TurnAdmission.Full {
                // Queue capacity was refused before the chat closure ran. Keep
                // exact completion identity but allow a later delivery retry.
                var retryable = !lifecycleClaimed
                if lifecycleClaimed, !responseCached, let deliveryId, let completionRequestDigest {
                    do {
                        try await CodexCompletionLifecycle.shared.markNotStarted(
                            deliveryId: deliveryId, requestDigest: completionRequestDigest)
                        retryable = true
                    } catch { retryable = false }
                }
                guard workLatch.claim() else { return }
                response(retryable ? 429 : 503, [
                    "requestId": requestID, "status": "not_started", "retryable": retryable,
                    "error": "bridge_chat_queue_full", "detail": "No model turn started; this chat's bridge queue is full.",
                ])
            } catch is CancellationError {
                await self.port.publishChatTurnCompleted(sessionID: sessionId)
                // Cancellation retains the persisted partial and releases the
                // completion claim as unknown, without a duplicate failure row.
                var cancelObject: [String: Any] = [
                    "requestId": requestID,
                    "status": "cancelled",
                    "reply": "(turn cancelled)",
                ]
                if lifecycleClaimed, !responseCached,
                   let deliveryId, let completionRequestDigest {
                    do {
                        try await CodexCompletionLifecycle.shared.markOutcomeUnknown(
                            deliveryId: deliveryId,
                            requestDigest: completionRequestDigest,
                            detail: "work_deadline_cancelled:\(Self.messageWorkDeadlineSeconds)s"
                        )
                    } catch {
                        cancelObject["detail"] =
                            "outcome receipt failed: \(String(describing: error))"
                    }
                }
                // Outcome settlement is unconditional; the response requires the latch.
                guard workLatch.claim() else { return }
                response(200, cancelObject)
            } catch {
                await self.port.publishChatTurnCompleted(sessionID: sessionId)
                var failureStatus = "chat_failed"
                var failureDetail = String(describing: error)
                if lifecycleClaimed, !responseCached,
                   let deliveryId, let completionRequestDigest {
                    do {
                        try await CodexCompletionLifecycle.shared.markOutcomeUnknown(
                            deliveryId: deliveryId,
                            requestDigest: completionRequestDigest,
                            detail: "chat_or_cache_failed:\(failureDetail)"
                        )
                        failureStatus = "outcome_unknown"
                    } catch {
                        failureStatus = "lifecycle_unavailable"
                        failureDetail += "; outcome receipt failed: \(String(describing: error))"
                    }
                } else if error is CodexCompletionLifecycle.LifecycleError {
                    // No model/tool dispatch happened when the initial durable
                    // claim failed. This is retryable lifecycle unavailability,
                    // not an ambiguous cognitive outcome.
                    failureStatus = "lifecycle_unavailable"
                }
                // Failure receipts retain the success envelope's timing context.
                Self.persistMessageReply([
                    "at": NativeTimestampFormat.plainZulu(Date()),
                    "status": failureStatus,
                    "sessionId": sessionId ?? NSNull(),
                    "model": NSNull(),
                    "runId": NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "reply": "",
                    "detail": failureDetail,
                    "deliveryId": deliveryId ?? NSNull(),
                ], requestID: requestID, principal: principal.id)
                self.eventPublisher("message_failed", [
                    "requestId": requestID,
                    "sessionId": sessionId ?? NSNull(),
                    "detail": failureDetail,
                    "status": failureStatus,
                ])
                guard workLatch.claim() else { return }
                response(failureStatus == "outcome_unknown" ? 409 : 500, [
                    "requestId": requestID,
                    "status": failureStatus,
                    "error": failureStatus,
                    "detail": failureDetail,
                    "deliveryId": deliveryId ?? NSNull(),
                ])
            }
        }
        // Reply receipts remain correlated by request identity after the HTTP wait ends.
        workLatch.arm(afterSeconds: Self.messageWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            self.eventPublisher("message_deadline_released", [
                "requestId": requestID,
                "seconds": Self.messageWorkDeadlineSeconds,
                "sessionId": sessionId ?? NSNull(),
            ])
            let pending = Self.pendingMessageReply(
                requestID: requestID, sessionID: sessionId
            )
            response(202, pending)
        }
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
        // Historical combined statuses describe delivery after a completed turn.
        let historical = row["status"] as? String ?? ""
        let turnStatus = row["runId"] is String
            && (historical.hasPrefix("delivery_") || ["ok", "no_reply", "outcome_unknown", "owed", "sent_unconfirmed"].contains(historical))
            ? "completed" : historical
        result["execution_result_class"] = row["execution_result_class"]
            ?? ChatToolOutcome.exactResultClass(.object(["status": .string(turnStatus)])).rawValue
        result["execution_terminal"] = row["execution_terminal"] ?? true
        for key in ["attachments", "completionDelivery", "deliveryId"] { result[key] = row[key] }
        result["run_id"] = row["runId"] as? String ?? NSNull()
        result["reply"] = slice
        result["offset"] = offset
        result["next_offset"] = offset + slice.count
        result["has_more"] = offset + slice.count < reply.count
        return finish("exact_receipt", complete: true)
    }

    static func pendingMessageReply(
        requestID: String, sessionID: String?,
        home: URL? = nil
    ) -> [String: Any] {
        [
            "status": "still_working",
            "requestId": requestID,
            "seconds": messageWorkDeadlineSeconds,
            "sessionId": sessionID ?? NSNull(),
            "replyReceipt": [
                "path": messageReplyURL(home: home).path,
                "format": "jsonl",
                "match": ["requestId": requestID],
                "retention": "Best-effort local receipt; trims to the newest ~4 MB once the file passes 8 MB. No fixed availability guarantee. A missing row does not prove failure.",
            ],
            "detail": "The HTTP wait ended; the original turn was not cancelled. Inspect its eventual receipt by requestId or its transcript. Do not resend the work merely because the receipt is not present yet.",
        ]
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
        if let claudeReplyID {
            try Self.recordClaudeReply(to: claudeReplyID, text: replyText, sessionId: turnSession,
                                       owner: owner, principal: principal, request: request)
            await answerAskingChat(replyTo: claudeReplyID, response: resp, turnSession: turnSession, owner: owner)
        }
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
        var receipt = result
        receipt["at"] = NativeTimestampFormat.plainZulu(Date())
        let written = Self.persistMessageReply(receipt, requestID: requestID, principal: principal.id)
        if deliveryID == nil, written {
            try await CodexCompletionLifecycle.shared.recordDelivery(AgentBridgeCompletionDelivery(status: "completed",
                surface: "bridge-http", delivery: "receipt", artifactCount: 1, attempts: 0, reason: nil),
                deliveryId: "bridge-http." + requestID, requestDigest: requestID)
        }
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

    /// Acknowledge the durable row before running its turn; replies use the shared receipt/event path.
    /// `enqueue_failed` and `enqueue_timeout` leave enqueue unproven; resolve ambiguity in the session store.
    private func handleMessageAckOnEnqueue(
        response: @escaping Response,
        client: SwiftNativeChatOrchestrationClient,
        request: TurnRequest,
        principal: AgentBridgePrincipal,
        claudeReplyID: String?,
        claudeReplyText: String,
        requestID: String,
        started: Date,
        /// false delivers transcript history without starting a turn or loading tools.
        runTurn: Bool = true
    ) {
        let enqueueLatch = ClaudeBridgeRuntime.WorkLatch()
        let owner = AgentContactIdentity(dataRoot: PersistenceCore.defaultDataRoot()).canonical("peer:" + principal.id)
        let sessionId = request.sessionID
        let text = request.message
        // The enqueued row is the turn's durable user message, including its images.
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let enqueued: EnqueuedUserMessage
            do {
                enqueued = try await request.enqueue(
                    on: client,
                    // The protocol flag, never message text, identifies a transport notice.
                    mechanicalRow: runTurn ? nil : .transportNotice,
                    awaitingConsumption: runTurn
                )
            } catch {
                guard enqueueLatch.claim() else { return }
                self.eventPublisher("message_enqueue_failed", [
                    "detail": String(describing: error),
                    "sessionId": sessionId ?? NSNull(),
                ])
                response(500, [
                    "status": "enqueue_failed",
                    "error": "enqueue_failed",
                    "detail": String(describing: error),
                ])
                return
            }
            guard enqueueLatch.claim() else {
                // The deadline owns the acknowledgement; a possibly persisted row must not start a turn.
                return
            }
            let receipt: [String: Any] = [
                "status": "ok",
                "requestId": requestID,
                "ack": "enqueued",
                "sessionId": enqueued.sessionId,
                "enqueuedAt": NativeTimestampFormat.plainZulu(Date()),
                "turn": runTurn ? "started" : "suppressed",
            ]
            response(200, receipt)
            self.eventPublisher("message_enqueued", [
                "requestId": requestID,
                "runId": enqueued.runId,
                "sessionId": enqueued.sessionId,
                "textLen": text.count,
                "turn": runTurn ? "started" : "suppressed",
            ])
            // The durable row proves notice delivery without starting a turn.
            guard runTurn else {
                // Publish the notice row to Mac and iOS transcripts.
                await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                return
            }
            do {
                // Reuse the enqueued run identity to exclude its user row from history and correlate the reply.
                var turn = request.consuming(enqueued)
                turn.codexCompletion = .some(.some(CodexCompletionTranscriptBinding(
                    deliveryId: "bridge-http." + requestID, requestDigest: requestID, model: "", reasoningEffort: nil)))
                _ = try await CodexCompletionLifecycle.shared.claim(deliveryId: "bridge-http." + requestID,
                    requestDigest: requestID, sessionId: enqueued.sessionId, responseRunId: enqueued.runId, principal: principal.id)
                let resp = try await TurnAdmission.admittedRun(dataRoot: PersistenceCore.defaultDataRoot(),
                    sessionID: enqueued.sessionId, runID: enqueued.runId) {
                    try await turn.chat(on: client, progress: self.chatNoticeSink(
                        requestID: requestID,
                        sessionID: enqueued.sessionId,
                        runID: enqueued.runId
                    ))
                }
                try await CodexCompletionLifecycle.shared.cacheResponse(resp, deliveryId: "bridge-http." + requestID, requestDigest: requestID)
                _ = try await self.settleMessageReply(resp, request: request, principal: principal, owner: owner,
                    claudeReplyID: claudeReplyID, replyText: claudeReplyText, requestID: requestID,
                    started: started, sessionID: enqueued.sessionId, enqueued: true)
            } catch {
                await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                let cancelled = error is CancellationError
                let status = cancelled ? "cancelled" : "chat_failed"
                let detail = cancelled ? "turn stopped before it finished" : String(describing: error)
                // Cancellation retains the already-persisted partial; only a receipt is owed here.
                Self.persistMessageReply([
                    "at": NativeTimestampFormat.plainZulu(Date()),
                    "status": status,
                    "ack": "enqueued",
                    "sessionId": enqueued.sessionId,
                    "model": NSNull(),
                    "runId": cancelled ? enqueued.runId as Any : NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "reply": "",
                    "detail": detail,
                ], requestID: requestID, principal: principal.id)
                self.eventPublisher("message_failed", [
                    "requestId": requestID,
                    "runId": enqueued.runId,
                    "detail": detail,
                    "status": status,
                    "sessionId": enqueued.sessionId,
                ])
            }
        }
        enqueueLatch.arm(afterSeconds: Self.enqueueAckDeadlineSeconds) { [weak self] in
            guard let self, enqueueLatch.claim() else { return }
            // Owning the enqueue latch prevents turn admission after this timeout.
            workTask.cancel()
            self.eventPublisher("message_enqueue_timeout", [
                "seconds": Self.enqueueAckDeadlineSeconds,
                "sessionId": sessionId ?? NSNull(),
            ])
            response(504, [
                "error": "enqueue_timeout",
                "status": "enqueue_timeout",
                "seconds": Self.enqueueAckDeadlineSeconds,
            ])
        }
    }

    /// Serialize best-effort reply JSONL appends; persistence failures log without failing HTTP.
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
    static func validClaudeReplyID(_ messageID: String, owner: String) -> String? {
        let root = PersistenceCore.defaultDataRoot()
        let identity = AgentContactIdentity(dataRoot: root)
        guard !messageID.isEmpty, messageID.utf8.count <= 128,
              let records = try? AgentConversationStore(dataRoot: root).records(),
              records.contains(where: { identity.canonical($0.agent) == owner && $0.readInput?["message_id"] == .string(messageID) }) else { return nil }
        return messageID
    }

    /// A message naming neither a send nor a conversation answers nothing.
    static func claudeReplyID(_ json: [String: Any], owner: String) -> String? {
        if let named = (json["reply_to"] ?? json["in_reply_to"]) as? String, !named.isEmpty {
            return validClaudeReplyID(named, owner: owner)
        }
        guard let conversation = json["conversation_id"] as? String, !conversation.isEmpty, conversation.utf8.count <= 512
        else { return nil }
        return (try? AgentConversationStore(dataRoot: PersistenceCore.defaultDataRoot())
            .waitingMessage(agent: owner, conversationID: conversation)).flatMap { validClaudeReplyID($0, owner: owner) }
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
        guard AgentContactIdentity(dataRoot: dataRoot).aliases["claude"] == owner else { return }
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

    /// The answer goes back to the chat that asked, from this who's own conversation.
    func answerAskingChat(replyTo messageID: String, response: ChatTurnRuntime.ChatResponse, turnSession: String?, owner: String) async {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let identity = AgentContactIdentity(dataRoot: dataRoot)
        let threadOwner = owner.hasPrefix("peer:") ? String(owner.dropFirst(5)) : owner
        let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
        guard let turnSession, turnSession == ContactThread.session(owner: threadOwner),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(response.attachments ?? []).isEmpty,
              let row = try? AgentConversationStore(dataRoot: dataRoot).records().first(where: {
                  identity.canonical($0.agent) == owner && $0.readInput?["message_id"] == .string(messageID)
              }), row.scopeSessionID != turnSession else { return }
        let deliveryId = owner + "-reply:" + messageID
        let route = AgentBridgeCompletionRoute(asking: row, turnSessionId: turnSession)
        let digest = SHA256.hash(data: Data(answer.utf8)).map { String(format: "%02x", $0) }.joined()
        let lifecycle = CodexCompletionLifecycle.shared
        // Once per answer: a resent reply never answers the asking chat twice.
        guard (try? await lifecycle.claim(deliveryId: deliveryId, requestDigest: digest, sessionId: turnSession,
                                         responseRunId: response.runId, route: route)) == .start else { return }
        do { try await lifecycle.cacheResponse(response, deliveryId: deliveryId, requestDigest: digest) } catch {
            nativeLog("ClaudeBridgeMessageRuntime: answer to %@ not recorded: %@", messageID, error.localizedDescription)
            return
        }
        let delivery = await AgentBridgeCompletionRouter.deliverAnswer(deliveryId: deliveryId, requestDigest: digest,
            text: answer, attachments: response.attachments ?? [],
            route: route, client: chatClient(),
            sender: port.completionSender(dataRoot: dataRoot), lifecycle: lifecycle, notifyRequestedResult: false)
        if delivery.status != "completed" {
            nativeLog("ClaudeBridgeMessageRuntime: answer to %@ %@: %@", messageID, delivery.status, delivery.reason ?? "")
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
            return try CredentialFileLock.withLock(file) {
                guard JSONSerialization.isValidJSONObject(payload),
                      let data = try? JSONSerialization.data(withJSONObject: payload) else {
                    nativeLog("[ClaudeBridge] message-reply persist skipped: payload not JSON-serializable")
                    return false
                }
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
        } catch {
            nativeLog("[ClaudeBridge] message-reply persist failed: %@", String(describing: error))
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
            try await TurnAdmission.shared.run(sessionID: sessionID, runID: runID, waitForCapacity: waitForCapacity, operation: operation)
        }
    }
}
