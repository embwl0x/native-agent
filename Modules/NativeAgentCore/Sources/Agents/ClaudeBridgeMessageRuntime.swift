import Foundation
import ChatTurnContracts
import Darwin
import CryptoKit
import ChatOrchestration
import AgentWorkspace
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import TurnTrace
import Transcripts

/// App selection, transport publication and existing delivery adapters used by
/// the Core conversation owner. Authentication happens before this boundary.
public protocol ClaudeBridgeMessagePort: Sendable {
    func activeSessionID(dataRoot: URL) -> String?
    func activePersona(dataRoot: URL) -> String?
    func chatClient() -> any ChatOrchestrationClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func publishChatTurnCompleted(sessionID: String?) async
    func handleCodexCompletion(messageIds: [String], codexStatus: String, summary: String,
                               threadId: String?, turnId: String?, errorMessage: String?,
                               noWorkObserved: Bool?) async
}

/// Admission, enqueue, completion and durable return receipts for the existing
/// bridge conversation. This owner has no Network connection or listener.
public final class ClaudeBridgeMessageRuntime: @unchecked Sendable {
    public typealias Response = @Sendable (Int, [String: Any]) -> Void
    /// U5 W-G (2026-06-11): upper bound on the WORK phase of /claude/message
    /// (one full LLM turn incl. tool loop). The read-phase deadline above is
    /// cancelled in `route(...)` once the body lands, so before this nothing
    /// bounded the detached work Task — a hung turn leaked the connection +
    /// Task forever.
    public static let messageWorkDeadlineSeconds: Int = 600
    /// Ack-on-enqueue lane (wake-delivery-classification, 2026-07-25): bound
    /// on the ENQUEUE phase only — a durable transcript append, disk-bound,
    /// measured in seconds. The turn that follows is deliberately unbounded
    /// here (the engine's own guards bound it); its outcome reaches callers
    /// through the durable reply JSONL and bridge events, never this response.
    public static let enqueueAckDeadlineSeconds: Int = 30
    private let port: any ClaudeBridgeMessagePort
    private let tasks: AgentContactTasks
    private let eventPublisher: @Sendable (String, [String: Any]) -> Void
    private let clientLock = NSLock()
    private var cachedChatClient: (any ChatOrchestrationClient)?


    public init(port: any ClaudeBridgeMessagePort, tasks: AgentContactTasks,
                eventPublisher: @escaping @Sendable (String, [String: Any]) -> Void) {
        self.port = port
        self.tasks = tasks
        self.eventPublisher = eventPublisher
    }

    private func chatClient() -> any ChatOrchestrationClient {
        clientLock.withLock {
            if let cachedChatClient { return cachedChatClient }
            let client = port.chatClient()
            cachedChatClient = client
            return client
        }
    }

    /// Everything the inbound peer lanes know about ONE peer request: who the
    /// caller proved it is (never the shared bridge bearer alone), which
    /// protocol it arrived on, the id that protocol carries, and a digest of
    /// the exact bytes. See `AgentBridgePrincipal` and
    /// `AgentPeerReplayClaimStore`.
    public struct PeerTurnContext: Sendable {
        public let principal: AgentBridgePrincipal
        public let protocolName: String
        public let messageID: String?
        public let bodyDigest: String

        public init(principal: AgentBridgePrincipal, protocolName: String, messageID: String?, bodyDigest: String) {
            self.principal = principal
            self.protocolName = protocolName
            self.messageID = messageID
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
    /// A peer's conversations live under its own prefix, so a peer can never
    /// name the person's session (or another peer's) and land a turn in it
    /// (Astra comb, 2026-09-16). `owner` is the authenticated principal id;
    /// a requested id must carry that peer's prefix or it is refused.
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
        let owner = AgentContactIdentity(dataRoot: dataRoot).canonical("peer:" + principal.id)
        let threadOwner = owner.hasPrefix("peer:") ? String(owner.dropFirst(5)) : owner
        let requestedSessionId = json["sessionId"] as? String
        // Real artifacts over the bridge (2026-09-02): a studio consult needs
        // the image, not a description of it. `image_paths` are local files
        // the caller already has; each becomes a chat attachment exactly as a
        // pasted image in the Mac composer would. Bounded: image types only,
        // 8 MB each, four per message; anything else is skipped, never a 400.
        let attachments = Self.bridgeImageAttachments(json["image_paths"] as? [String] ?? [])
        // Agent, 2026-09-02: an image that could not be attached used to
        // vanish; the message now says so, so a header without pixels is
        // never a mystery on her side.
        let imageSkips = Self.bridgeImageSkips(json["image_paths"] as? [String] ?? [])
        // A named lane's message that names no chat goes on in that lane's own
        // conversation (below); a script's notice inherits the session the
        // state route advertises. Completion callbacks keep their explicit
        // routing semantics.
        // Agent, 2026-09-02: a script's receipt must not wear a person's
        // name. A small allowlist of non-human senders may name themselves in
        // the body; everything else stays the route's default.
        let sender: String = {
            if let named = (json["sender"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               Self.scriptSenders.contains(named) {
                return named
            }
            return defaultSender
        }()
        // A lane's own message, naming no chat, goes on in its conversation
        // with her (User 10-01), not in whatever chat the Mac has open; a
        // script's notice still lands there.
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
        let githubCommandCompletion: (messageIds: [String], status: String, threadId: String?, turnId: String?, errorMessage: String?, noWorkObserved: Bool?)? = {
            guard let completion = json["completion"] as? [String: Any] else { return nil }
            let messageIds = (completion["messageIds"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard !messageIds.isEmpty else { return nil }
            return (
                messageIds,
                completion["codexStatus"] as? String ?? "unknown",
                completion["threadId"] as? String,
                completion["turnId"] as? String,
                // JSON null decodes as NSNull, which fails both casts to nil —
                // exactly the "unknown" reading the three-state field wants.
                completion["errorMessage"] as? String,
                completion["noWorkObserved"] as? Bool
            )
        }()
        let completionRoute: AgentBridgeCompletionRoute? = {
            guard isCodexCompletion else { return nil }
            return AgentBridgeCompletionRoute(
                origin: json["origin"] as? [String: Any],
                sessionId: sessionId
            )
        }()
        let claudeReplyID = Self.claudeReplyID(json, owner: owner)
        let baseRequest: TurnRequest = {
            var request = principal.turnRequest(context: nil, plain: rawText, attachments: attachments, originID: claudeReplyID)
            request.sessionID = sessionId
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
        // Ack-on-enqueue lane (wake-delivery-classification, 2026-07-25): a
        // caller that sends `ackMode: "enqueue"` gets its HTTP response the
        // moment the message row is durably in the session store — never
        // coupled to turn completion. The legacy lane below couples the two,
        // which self-deadlocks any caller whose POST both starts and waits on
        // the same turn (the wake helper's structural false-negative class).
        // Codex COMPLETIONS stay on the legacy lane: their response semantics
        // (claim/settled/conflict) are load-bearing for at-most-once delivery.
        // "enqueue_only" is the same durable-append lane with the turn
        // suppressed (astra-comb-3 lane3 #1): the wake helper uses it for a
        // reply-free transport event, which used to arrive as a full
        // tool-capable decision turn and made the agent re-decide — and
        // contradict — work its own in-flight turn had already decided.
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
        // U5 W-G: bound the work phase. The latch makes the work Task and the
        // deadline timer race for the single response write; the loser no-ops.
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
                let resp: ChatOrchestration.ChatResponse
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
                        if let completion = githubCommandCompletion {
                            await self.port.handleCodexCompletion(
                                messageIds: completion.messageIds,
                                codexStatus: completion.status,
                                summary: rawText,
                                threadId: completion.threadId,
                                turnId: completion.turnId,
                                errorMessage: completion.errorMessage,
                                noWorkObserved: completion.noWorkObserved
                            )
                        }
                        var request = baseRequest
                        request.replyRoute = completionRoute?.chatToolReplyRoute
                        request.pinnedRunID = responseRunID
                        request.codexCompletion = CodexCompletionTranscriptBinding(
                                deliveryId: deliveryId,
                                requestDigest: completionRequestDigest,
                                // Canonical assistant persistence replaces
                                // these placeholders with executed truth.
                                model: "",
                                reasoningEffort: nil
                        )
                        let generated: ChatOrchestration.ChatResponse
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
                    if let completion = githubCommandCompletion {
                        await self.port.handleCodexCompletion(
                            messageIds: completion.messageIds,
                            codexStatus: completion.status,
                            summary: rawText,
                            threadId: completion.threadId,
                            turnId: completion.turnId,
                            errorMessage: completion.errorMessage,
                            noWorkObserved: completion.noWorkObserved
                        )
                    }
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
                if !callerResultIsTool {
                    await self.port.publishChatTurnCompleted(sessionID: resp.sessionId ?? sessionId)
                }
                if let claudeReplyID {
                    Self.recordClaudeReply(to: claudeReplyID, text: rawText, sessionId: resp.sessionId ?? sessionId, owner: owner)
                    await self.answerAskingChat(replyTo: claudeReplyID, response: resp, turnSession: resp.sessionId ?? sessionId, owner: owner)
                }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let trimmedReply = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentPayload = Self.bridgeAttachmentPayload(resp.attachments)
                // The chat return follows canonical assistant persistence. A
                // later notification failure cannot undo that arrival.
                let replyPersisted = responseCached && !callerResultIsTool && (!trimmedReply.isEmpty || !attachmentPayload.isEmpty)
                let completionDelivery: AgentBridgeCompletionDelivery?
                if let completionRoute,
                   let deliveryId,
                   let completionRequestDigest,
                   !trimmedReply.isEmpty || !(resp.attachments ?? []).isEmpty {
                    completionDelivery = await AgentBridgeCompletionRouter.deliver(
                        deliveryId: deliveryId,
                        requestDigest: completionRequestDigest,
                        text: resp.output,
                        attachments: resp.attachments ?? [],
                        route: completionRoute,
                        sender: self.port.completionSender(dataRoot: dataRoot),
                        lifecycle: CodexCompletionLifecycle.shared
                    )
                } else {
                    completionDelivery = nil
                }
                let replyStatus = Self.codexCompletionReplyStatus(
                    terminalState: resp.terminalState,
                    hasReplyText: !trimmedReply.isEmpty,
                    attachmentCount: attachmentPayload.count,
                    completionDeliveryStatus: completionDelivery?.status
                )
                var persistedReply: [String: Any] = [
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": replyStatus,
                    "sessionId": resp.sessionId ?? NSNull(),
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                    "responseCached": responseCached,
                    "servedFromCache": wasCached,
                    "replyPersisted": replyPersisted,
                ]
                if let deliveryId { persistedReply["deliveryId"] = deliveryId }
                if let completionDelivery {
                    persistedReply["completionDelivery"] = completionDelivery.jsonObject
                }
                let receiptWritten = Self.persistMessageReply(persistedReply, requestID: requestID, principal: principal.id)
                if deliveryId == nil, receiptWritten {
                    try await CodexCompletionLifecycle.shared.recordDelivery(AgentBridgeCompletionDelivery(status: "completed",
                        surface: "bridge-http", delivery: "receipt", artifactCount: 1, attempts: 0, reason: nil),
                        deliveryId: "bridge-http." + requestID, requestDigest: requestID)
                }
                // Publish: bridge got the reply (her → me).
                self.eventPublisher("message_out", [
                    "requestId": requestID,
                    "sessionId": resp.sessionId ?? NSNull(),
                    "model": resp.model,
                    "runId": resp.runId,
                    "replyLen": resp.output.count,
                    "attachmentCount": attachmentPayload.count,
                    "durationMs": durationMs,
                    "status": replyStatus,
                    "completionDeliveryStatus": completionDelivery?.status ?? NSNull(),
                    "deliveryId": deliveryId ?? NSNull(),
                    "servedFromCache": wasCached,
                ])
                // Fail LOUD on empty: an empty reply is not a success — the
                // caller must know the cargo didn't arrive (status field; HTTP
                // stays 200 so existing callers' transport handling is unchanged).
                // (Persist + publish above run even after a work-timeout — the
                // durable JSONL drop is exactly for replies with nowhere to go.)
                guard workLatch.claim() else { return }
                var responseObject: [String: Any] = [
                    "requestId": requestID,
                    "status": replyStatus,
                    "sessionId": resp.sessionId ?? NSNull(),
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "responseCached": responseCached,
                    "servedFromCache": wasCached,
                    "replyPersisted": replyPersisted,
                ]
                if let deliveryId { responseObject["deliveryId"] = deliveryId }
                if let completionDelivery {
                    responseObject["completionDelivery"] = completionDelivery.jsonObject
                }
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
                // 2026-07-21 gpt-5.5 review: the bridge deadline cancels the
                // work task — a cancel is NOT a chat failure. The cancelled
                // partial already persisted via streamCancelled; writing a
                // chat_failed/message_failed row after it double-books the
                // turn. Reply 499-style (no failure row).
                //
                // 2026-07-31: the claim still has to be RELEASED. A cancel here
                // means the 600s work deadline fired mid-turn; without the same
                // outcome receipt the generic catch writes, the lifecycle stays
                // .claimed under THIS ownerInstanceId, claim() answers
                // .inProgress for us forever (reconcileInterruptedClaims only
                // sweeps other instance ids), and every node-side retry gets
                // 202 completion_in_progress until relaunch. Ambiguous, not
                // failed — markOutcomeUnknown is exactly that receipt.
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
                // The outcome receipt above always runs — lifecycle truth is
                // unconditional. The RESPONSE is not: the 600s deadline handler
                // that cancelled us claims the latch before answering 504, so
                // writing here without claiming would put a second HTTP
                // response on the same connection (gpt-5.5 wave review,
                // 2026-07-31). Loser of the race stays silent.
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
                // Same envelope shape as the success row (gpt-5.5 review: don't
                // make consumers special-case failures or lose timing context).
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
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
        // Release only the HTTP wait. The original turn is not cancelled;
        // its existing durable reply can be correlated by request identity.
        workLatch.arm(afterSeconds: Self.messageWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            // User, 2026-09-05: "her turn shouldn't be dying on her while she's
            // working." This deadline used to cancel the work task, and the
            // work task IS the turn: a bridge message that started a long
            // curation turn had that turn killed ten minutes in, silently, at
            // the next tool boundary (10:00:24 -> 10:10:24 -> died 10:12:15).
            // The deadline now releases only the HTTP caller. The turn runs
            // to its own end; its reply still lands in the transcript and in
            // the bridge's reply record, and the caller reads it from there.
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
            // Older receipts have several shapes, including rows without a
            // reply/status. A fully decoded object with no matching request ID
            // is demonstrably unrelated; validate the payload only after exact
            // identity matches. Malformed JSON still cannot establish scope.
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
        return record
    }

    /// Ack-on-enqueue lane for /claude/message and plain /codex/message
    /// (wake-delivery-classification, 2026-07-25). Two phases, one response:
    ///
    ///   1. ENQUEUE — durably append the user row; answer 200
    ///      {status:"ok", ack:"enqueued", sessionId} immediately. Bounded by
    ///      `enqueueAckDeadlineSeconds` (disk-bound work).
    ///   2. TURN — run the chat turn detached with `suppressUserAppend: true`
    ///      on the RESOLVED session. Unbounded here by design: the response is
    ///      already written, so a long turn can no longer be misread as a lost
    ///      delivery. The reply still lands in message-replies.jsonl and the
    ///      message_out/message_failed event stream, same as the legacy lane.
    ///
    /// Honesty contract with callers: `enqueue_failed` and `enqueue_timeout`
    /// mean "not proven enqueued", NOT "proven not enqueued" — post-append
    /// bookkeeping inside the append seam can throw after the row is on disk.
    /// Callers settle ambiguity against the session store itself.
    private func handleMessageAckOnEnqueue(
        response: @escaping Response,
        client: any ChatOrchestrationClient,
        request: TurnRequest,
        principal: AgentBridgePrincipal,
        claudeReplyID: String?,
        claudeReplyText: String,
        requestID: String,
        started: Date,
        /// false = notice delivery: append the row, answer the ack, run NO
        /// turn. The row is ordinary transcript history the agent reads on its
        /// next real turn; it starts no decision and loads no tools.
        runTurn: Bool = true
    ) {
        let enqueueLatch = ClaudeBridgeRuntime.WorkLatch()
        let owner = AgentContactIdentity(dataRoot: PersistenceCore.defaultDataRoot()).canonical("peer:" + principal.id)
        let sessionId = request.sessionID
        let text = request.message
        // 2026-09-06: the enqueued row is the ONLY durable user message on
        // this lane — the turn below runs with suppressUserAppend, so images
        // that reached the model left no trace in the transcript at all.
        let workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let enqueued: EnqueuedUserMessage
            do {
                enqueued = try await request.enqueue(
                    on: client,
                    // TRANSPORT BOOKKEEPING, DECLARED BY THE SENDER (Agent,
                    // item 5, 2026-09-14). `runTurn == false` is the
                    // `enqueue_only` lane: a reply-free transport event that
                    // starts no decision and loads no tools — the
                    // "[claude-wake] [notice] Transport record only…" rows.
                    // The felt organ was reading those as things User said to her.
                    //
                    // Off the LANE, never the text. The notice wording lives in
                    // script/wake_reply_delivery.js, outside Swift entirely, so
                    // matching it here would tie her inner life to a string in
                    // another language's source. The protocol flag is the fact.
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
                // The enqueue deadline already answered 504. The row may be
                // durably in the store; running the turn anyway would let a
                // wake that LOOKS failed also speak. Stop — the caller's
                // store check classifies the ambiguity honestly.
                return
            }
            let receipt: [String: Any] = [
                "status": "ok",
                "requestId": requestID,
                "ack": "enqueued",
                "sessionId": enqueued.sessionId,
                "enqueuedAt": ISO8601DateFormatter().string(from: Date()),
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
            // Notice delivery ends here. The caller's proof of delivery is the
            // durable row itself (confirmDeliveryViaSessionStore reads the
            // store, not this response), so suppressing the turn costs the
            // delivery contract nothing.
            guard runTurn else {
                // Same refresh edge a turn would publish, so the informational
                // row actually appears in the Mac transcript and the iOS
                // projection instead of waiting for the next turn.
                await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                return
            }
            do {
                // Pin the turn's runId to the enqueued row's runId so history
                // exclusion drops the pre-appended user row (else the message
                // enters the prompt twice) and user/assistant rows correlate
                // exactly as on the normal append-inside-turn path.
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
                await self.port.publishChatTurnCompleted(sessionID: resp.sessionId ?? enqueued.sessionId)
                if let claudeReplyID {
                    Self.recordClaudeReply(to: claudeReplyID, text: claudeReplyText, sessionId: resp.sessionId ?? enqueued.sessionId, owner: owner)
                    await self.answerAskingChat(replyTo: claudeReplyID, response: resp, turnSession: resp.sessionId ?? enqueued.sessionId, owner: owner)
                }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let trimmedReply = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentPayload = Self.bridgeAttachmentPayload(resp.attachments)
                let replyStatus = Self.codexCompletionReplyStatus(
                    terminalState: resp.terminalState,
                    hasReplyText: !trimmedReply.isEmpty,
                    attachmentCount: attachmentPayload.count,
                    completionDeliveryStatus: nil
                )
                let receiptWritten = Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": replyStatus,
                    "ack": "enqueued",
                    "sessionId": resp.sessionId ?? enqueued.sessionId,
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                ], requestID: requestID, principal: principal.id)
                if receiptWritten {
                    try await CodexCompletionLifecycle.shared.recordDelivery(AgentBridgeCompletionDelivery(status: "completed",
                        surface: "bridge-http", delivery: "receipt", artifactCount: 1, attempts: 0, reason: nil),
                        deliveryId: "bridge-http." + requestID, requestDigest: requestID)
                }
                self.eventPublisher("message_out", [
                    "requestId": requestID,
                    "sessionId": resp.sessionId ?? enqueued.sessionId,
                    "model": resp.model,
                    "runId": resp.runId,
                    "replyLen": resp.output.count,
                    "attachmentCount": attachmentPayload.count,
                    "durationMs": durationMs,
                    "status": replyStatus,
                    "ack": "enqueued",
                ])
            } catch is CancellationError {
                await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                // A Stop on this session (cancelled.flag is per session, and
                // bridge turns share the Mac's) cancels the turn after the
                // ack. The caller was told to read the receipt, so write one:
                // without it they wait forever. Receipt file only, no chat
                // row (the cancelled partial is already in the transcript).
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": "cancelled",
                    "ack": "enqueued",
                    "sessionId": enqueued.sessionId,
                    "model": NSNull(),
                    "runId": enqueued.runId,
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "reply": "",
                    "detail": "turn stopped before it finished",
                ], requestID: requestID, principal: principal.id)
                self.eventPublisher("message_failed", [
                    "requestId": requestID,
                    "runId": enqueued.runId,
                    "detail": "turn stopped before it finished",
                    "status": "cancelled",
                    "sessionId": enqueued.sessionId,
                ])
            } catch {
                await self.port.publishChatTurnCompleted(sessionID: enqueued.sessionId)
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": "chat_failed",
                    "ack": "enqueued",
                    "sessionId": enqueued.sessionId,
                    "model": NSNull(),
                    "runId": NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "reply": "",
                    "detail": String(describing: error),
                ], requestID: requestID, principal: principal.id)
                self.eventPublisher("message_failed", [
                    "requestId": requestID,
                    "runId": enqueued.runId,
                    "detail": String(describing: error),
                    "status": "chat_failed",
                    "sessionId": enqueued.sessionId,
                ])
            }
        }
        enqueueLatch.arm(afterSeconds: Self.enqueueAckDeadlineSeconds) { [weak self] in
            guard let self, enqueueLatch.claim() else { return }
            // Cancel BEFORE the turn can start: the work task only proceeds
            // past the enqueue when ITS latch claim succeeds, so a claimed
            // deadline guarantees no ghost turn runs after this 504.
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

    /// Durable her→me drop: append one JSONL row per /claude/message turn to
    /// ~/.config/claude-bridge/message-replies.jsonl (sibling of the token +
    /// claude-inbox.jsonl). Survives client timeouts and empty turns — the two
    /// observed ways a reply evaporated. Best-effort by design: a persistence
    /// failure logs but never breaks the HTTP response path.
    /// Serializes message-reply appends — two concurrent detached turns must
    /// not interleave the existence-check/open/append sequence (gpt-5.5 review:
    /// lost/overwritten JSONL rows on the durability path).
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

    static func bridgeImageSkips(_ paths: [String]) -> [String] {
        let mimes: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
        var out: [String] = []
        for (index, raw) in paths.enumerated() {
            let url = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            let name = url.lastPathComponent
            if index >= 4 { out.append("\(name): past the four-image limit"); continue }
            guard mimes.contains(url.pathExtension.lowercased()) else { out.append("\(name): not an image type the bridge takes"); continue }
            guard FileManager.default.fileExists(atPath: url.path) else { out.append("\(name): not found"); continue }
            guard let data = try? Data(contentsOf: url) else { out.append("\(name): could not be read"); continue }
            if data.isEmpty { out.append("\(name): empty file (still being written?)"); continue }
            if data.count > 8 * 1024 * 1024 { out.append("\(name): over 8 MB"); continue }
        }
        return out
    }

    static func withImageSkipNote(_ text: String, _ skips: [String]) -> String {
        guard !skips.isEmpty else { return text }
        let noun = skips.count == 1 ? "image" : "images"
        // 2026-09-08 (Agent's acceptance): the notice must say how to recover, not only what failed.
        return text + "\n\n[\(skips.count) \(noun) not attached: " + skips.joined(separator: "; ") + ". The sender can resend the file\(skips.count == 1 ? "" : "s").]"
    }

    static func bridgeImageAttachments(_ paths: [String]) -> [ChatOrchestration.MultimodalAttachment] {
        let mimes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"]
        var out: [ChatOrchestration.MultimodalAttachment] = []
        for raw in paths.prefix(4) {
            let url = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let mime = mimes[url.pathExtension.lowercased()],
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty, data.count <= 8 * 1024 * 1024 else { continue }
            out.append(ChatOrchestration.MultimodalAttachment(
                type: "image", base64: data.base64EncodedString(), mime: mime,
                name: url.lastPathComponent, byteSize: data.count, path: url.path
            ))
        }
        return out
    }

    static func bridgeAttachmentPayload(
        _ attachments: [ChatOrchestration.MultimodalAttachment]?
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

    static func codexCompletionRequestDigest(_ json: [String: Any], attachments: [ChatOrchestration.MultimodalAttachment]) -> String? {
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

    /// Keep the bridge's top-level settlement honest. Attachment-only responses
    /// are real replies, while an ambiguous external send is terminal but is not
    /// success and must not invite another unsafe dispatch.
    static func codexCompletionReplyStatus(
        terminalState: TurnEngineResult.TerminalState?,
        hasReplyText: Bool,
        attachmentCount: Int,
        completionDeliveryStatus: String?
    ) -> String {
        guard terminalState == .completed else { return terminalState?.rawValue ?? "incomplete" }
        guard hasReplyText || attachmentCount > 0 else { return "no_reply" }
        switch completionDeliveryStatus {
        case "failed_pre_dispatch": return "delivery_failed_pre_dispatch"
        case "rejected": return "delivery_rejected"
        case "lifecycle_unavailable": return "delivery_lifecycle_unavailable"
        case "in_progress": return "delivery_in_progress"
        case "outcome_unknown": return "outcome_unknown"
        default: return "ok"
        }
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
    static func recordClaudeReply(to messageID: String, text: String, sessionId: String?, owner: String) {
        let dataRoot = PersistenceCore.defaultDataRoot()
        _ = try? AgentConversationStore(dataRoot: dataRoot)
            .settleReply(agent: owner, messageID: messageID, text: text, landedIn: sessionId)
        guard AgentContactIdentity(dataRoot: dataRoot).aliases["claude"] == owner else { return }
        let dir = messageReplyURL().deletingLastPathComponent()
        // The answer as every job retains it, so an exact read returns it, not a preview.
        let row: [String: Any] = [
            "messageId": messageID, "sessionId": sessionId ?? NSNull(),
            "replyText": String(text.prefix(6000)), "replyTruncated": text.count > 6000,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: row) else { return }
        line.append(0x0A)
        let file = dir.appendingPathComponent("claude-replies.jsonl")
        messageReplyLock.lock()
        defer { messageReplyLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: file.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        _ = try? enforceJSONLLineCap(at: file, maxLines: 500, trimWhenBytesExceed: 1_048_576)
    }

    /// The answer goes back to the chat that asked, from this who's own conversation.
    func answerAskingChat(replyTo messageID: String, response: ChatOrchestration.ChatResponse, turnSession: String?, owner: String) async {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let identity = AgentContactIdentity(dataRoot: dataRoot)
        let threadOwner = owner.hasPrefix("peer:") ? String(owner.dropFirst(5)) : owner
        guard let turnSession, turnSession == ContactThread.session(owner: threadOwner),
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(response.attachments ?? []).isEmpty,
              let row = try? AgentConversationStore(dataRoot: dataRoot).records().first(where: {
                  identity.canonical($0.agent) == owner && $0.readInput?["message_id"] == .string(messageID)
              }), row.scopeSessionID != turnSession else { return }
        let deliveryId = owner + "-reply:" + messageID
        let route = AgentBridgeCompletionRoute(asking: row, turnSessionId: turnSession)
        let digest = SHA256.hash(data: Data(response.output.utf8)).map { String(format: "%02x", $0) }.joined()
        let lifecycle = CodexCompletionLifecycle.shared
        // Once per answer: a resent reply never answers the asking chat twice.
        guard (try? await lifecycle.claim(deliveryId: deliveryId, requestDigest: digest, sessionId: turnSession,
                                         responseRunId: response.runId, route: route)) == .start else { return }
        do { try await lifecycle.cacheResponse(response, deliveryId: deliveryId, requestDigest: digest) } catch {
            nativeLog("ClaudeBridgeMessageRuntime: answer to %@ not recorded: %@", messageID, error.localizedDescription)
            return
        }
        let delivery = await AgentBridgeCompletionRouter.deliverAnswer(deliveryId: deliveryId, requestDigest: digest,
            text: response.output, attachments: response.attachments ?? [],
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
            let status = codexCompletionReplyStatus(terminalState: response.terminalState,
                hasReplyText: !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                attachmentCount: attachments.count, completionDeliveryStatus: nil)
            guard persistMessageReply(["at": ISO8601DateFormatter().string(from: Date()), "status": status,
                "sessionId": response.sessionId ?? "", "runId": response.runId, "model": response.model,
                "reply": response.output, "attachments": attachments, "replyPersisted": true], requestID: requestID,
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
            let lockFD = Darwin.open(file.path + ".lock", O_CREAT | O_WRONLY, 0o600)
            guard lockFD >= 0 else {
                throw NSError(
                    domain: "ClaudeBridgeMessageReply",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "could not open receipt lock"]
                )
            }
            defer {
                _ = flock(lockFD, LOCK_UN)
                Darwin.close(lockFD)
            }
            guard flock(lockFD, LOCK_EX) == 0 else {
                throw NSError(
                    domain: "ClaudeBridgeMessageReply",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "could not acquire receipt lock"]
                )
            }
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
            if !FileManager.default.fileExists(atPath: file.path) {
                try line.write(to: file, options: [.atomic])
            } else {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
                try handle.close()
            }
            // 2026-09-22: a byte cap, not a line cap. Rows are big (~2KB), so
            // the file sat past the 8MiB trigger but under 5000 lines and was
            // re-read whole on every append without ever trimming.
            let dropped = try enforceJSONLByteCap(
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
    ) -> ChatOrchestrationProgressHandler {
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
            try await TurnAdmission.shared.run(sessionID: sessionID, waitForCapacity: waitForCapacity, operation: operation)
        }
    }
}
