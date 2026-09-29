import Foundation
import Darwin
import CryptoKit
import ChatOrchestration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy

/// HTTP deadlines remain owned by the app connection adapter.
public protocol ClaudeBridgeResponseLatch: Sendable {
    func claim() -> Bool
    func arm(afterSeconds seconds: Int, _ body: @escaping @Sendable () -> Void)
}

/// App selection, transport publication and existing delivery adapters used by
/// the Core conversation owner. Authentication happens before this boundary.
public protocol ClaudeBridgeMessagePort: Sendable {
    func activeSessionID(dataRoot: URL) -> String?
    func activePersona(dataRoot: URL) -> String?
    func chatClient() -> any ChatOrchestrationClient
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending
    func makeResponseLatch() -> any ClaudeBridgeResponseLatch
    func publishEvent(kind: String, payload: [String: Any])
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

    public init(port: any ClaudeBridgeMessagePort) {
        self.port = port
    }

    private func writeProjectedMessage(_ response: Response, projection: (@Sendable (Int, [String: Any]) -> [String: Any])?, status: Int, obj: [String: Any]) {
        response(projection == nil ? status : 200, projection?(status, obj) ?? obj)
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

        public var claimKey: String? {
            guard let messageID, !messageID.isEmpty else { return nil }
            return AgentPeerReplayClaimStore.key(
                principal: principal.id, protocolName: protocolName, messageID: messageID
            )
        }
    }

    /// The name that goes in `[from: …, via bridge]`.
    ///
    /// The lane's own sender, unless the caller proved which CONTACT it is with
    /// that connection's own key — then the person's own name for that contact,
    /// because "agent" on every row tells them nothing about who is talking.
    /// Presentation only; it never reaches `laneAuthorship`, the surface, or any
    /// gate. The name is the person's own text from the contact store, so it is
    /// bounded and stripped of the brackets and newlines that would let it
    /// forge a second prefix.
    static func bridgeDisplayLabel(sender: String, peer: PeerTurnContext?) -> String {
        guard let raw = peer?.principal.displayName else { return sender }
        let cleaned = raw
            .components(separatedBy: CharacterSet.newlines).joined(separator: " ")
            .filter { $0 != "[" && $0 != "]" }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? sender : String(cleaned.prefix(120))
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

    public func handleMessage(response: @escaping Response, body: Data, defaultSender: String,
                               peer: PeerTurnContext? = nil,
                               responseProjection upstreamProjection: (@Sendable (Int, [String: Any]) -> [String: Any])? = nil) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeProjectedMessage(response, projection: upstreamProjection, status: 400, obj: ["error": "invalid_json"])
            return
        }
        if defaultSender == "agent" {
            guard Self.validGenericAgentMessage(json) else {
                writeProjectedMessage(response, projection: upstreamProjection, status: 400, obj: ["error": "invalid_agent_message_fields"])
                return
            }
        }
        guard let rawText = json["text"] as? String, !rawText.isEmpty else {
            writeProjectedMessage(response, projection: upstreamProjection, status: 400, obj: ["error": "missing_text"])
            return
        }
        // Accepted peer traffic is inbound evidence. Only an exact outstanding
        // challenge response can also prove this contact's MCP return path.
        if let peerID = peer?.principal.peerID {
            AgentPeerStore(dataRoot: PersistenceCore.defaultDataRoot()).recordProof(peerID: peerID, inbound: true, message: rawText)
        }
        let isCodexCompletion = defaultSender == "codex" && json["completion"] is [String: Any]
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
        // Named legacy bridge messages remain turns in the current chat.
        // The state route already publishes the selected live session as
        // `activeSessionId`, but the message route historically passed nil
        // through when callers omitted that optional field. Persistence then
        // rejected the turn as "missing chat session id", making a bridge that
        // reported chatReady=true fail its simplest documented request.
        // Completion callbacks keep their explicit routing semantics; only a
        // named inbound message inherits the session the state route advertises.
        // Generic peers own a fresh persistent conversation when omitted;
        // the mounted route creates its identity before canonical persistence.
        // Protocol context IDs are public locators. Persist them beneath the
        // authenticated owner's namespace, just like plain peer sessions.
        let protocolSession = peer.map { $0.protocolName == "mcp" || $0.protocolName == "a2a" } == true
            ? requestedSessionId : nil
        let ownerPrefix = peer.map { AgentBridgePrincipal.genericAgentSessionPrefix(owner: $0.principal.id) }
        let ownedRequestedSession = protocolSession.flatMap { session in
            ownerPrefix.map { $0 + session }
        } ?? requestedSessionId
        let responseProjection: (@Sendable (Int, [String: Any]) -> [String: Any])?
        if protocolSession != nil, let ownerPrefix {
            responseProjection = { status, receipt in
                var projected = receipt
                if let stored = receipt["sessionId"] as? String,
                   stored.hasPrefix(ownerPrefix) {
                    projected["sessionId"] = String(stored.dropFirst(ownerPrefix.count))
                }
                return upstreamProjection?(status, projected) ?? projected
            }
        } else { responseProjection = upstreamProjection }
        let sessionId = defaultSender == "agent"
            ? Self.genericAgentSessionID(requested: ownedRequestedSession, owner: peer?.principal.id)
            : Self.bridgeMessageSessionID(
            requested: requestedSessionId,
            active: isCodexCompletion
                ? nil
                : port.activeSessionID(dataRoot: PersistenceCore.defaultDataRoot())
        )
        if defaultSender == "agent", sessionId == nil {
            writeProjectedMessage(response, projection: responseProjection, status: 403, obj: [
                "error": "session_not_owned",
                "detail": "A peer may only continue conversations it started; omit sessionId to start one.",
            ])
            return
        }
        if !isCodexCompletion, sessionId == nil {
            writeProjectedMessage(response, projection: responseProjection, status: 409, obj: [
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
            writeProjectedMessage(response, projection: responseProjection, status: 400, obj: ["error": "codex_completion_delivery_id_missing"])
            return
        }
        let completionRequestDigest = isCodexCompletion
            ? Self.codexCompletionRequestDigest(json)
            : nil
        if isCodexCompletion && completionRequestDigest == nil {
            writeProjectedMessage(response, projection: responseProjection, status: 400, obj: ["error": "codex_completion_digest_failed"])
            return
        }
        let githubCommandCompletion: (messageIds: [String], status: String, threadId: String?, turnId: String?, errorMessage: String?, noWorkObserved: Bool?)? = {
            guard defaultSender == "codex", let completion = json["completion"] as? [String: Any] else { return nil }
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
            guard defaultSender == "codex", json["completion"] is [String: Any] else { return nil }
            return AgentBridgeCompletionRoute(
                origin: json["origin"] as? [String: Any],
                sessionId: sessionId
            )
        }()
        // Spec from 2026-06-07 night plan: "POST /claude/message {text} —
        // injects into current chat as sender: claude". Without this,
        // every bridge message reads to Agent as if it came from the user.
        // Trust-but-mark: we PREFIX the user-visible text with a [from:
        // claude] tag so her system context + chat history show it.
        // Human transcript readers also get a durable metadata.origin record;
        // the model still reads the prefix as prose context.
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
        // 658.14: the durable, out-of-band twin of the in-band prefix below.
        // The prefix is prose the model reads and ANYONE can type; this is the
        // server-recorded route field a transcript reader can distinguish from
        // prose. Authorization currently uses one shared bearer for every
        // route, so this does not independently attest the calling process.
        // Surface is derived from the sender rather than picked by a
        // two-way ternary. There is a THIRD lane — defaultSender "omp" at
        // :503 — and a `sender == "codex" ? codex : claude` test silently
        // labelled it "claude-bridge". A provenance indicator that names the
        // wrong lane is strictly worse than no indicator, so unknown senders
        // get their own surface string and fall through the render
        // allowlist's default to the honest, unattributed "Automated".
        // Item 8 (2026-09-02): authorship comes from the LANE TABLE above, not
        // from a blanket assumption about this bridge. The sender is the route,
        // never the request body, so the table is being asked exactly the
        // question it exists to answer: did an agent compose these words, or is
        // this lane carrying the human's?
        let claudeReplyID = sender == "claude" ? Self.claudeReplyID(json) : nil
        let origin = ChatMessageOrigin(
            surface: BridgeLane.bridgeSurfaceName(forSender: sender),
            agent: sender,
            authored: BridgeLane.laneAuthorship(forSender: sender),
            replyTo: claudeReplyID
        )
        // The in-band label. A peer that proved WHICH contact it is — its
        // connection's own key, resolved by `AgentBridgePrincipal` — is named
        // by that contact rather than by the generic lane, so the transcript
        // says who actually wrote. It is a DISPLAY LABEL and nothing more:
        // `sender`, the surface, the authorship table and every gate still see
        // the route, so a contact name can neither claim a lane nor change what
        // this turn is allowed to do.
        let label = Self.bridgeDisplayLabel(sender: sender, peer: peer)
        var text: String
        if sender == "claude" {
            text = "[from: claude, via bridge] \(rawText)"
        } else if defaultSender == "agent" {
            text = "[from: \(label), via bridge] \(AgentBridgeSurface.quotingImpersonation(rawText))"
        } else {
            text = "[from: \(label), via bridge] \(rawText)"
        }

        // The executable model + effort follow the Mac chat-surface selection.
        // The shared chat facade admits that canonical tuple on every turn and
        // canonical assistant persistence stamps the executed tuple into any
        // completion-recovery evidence. The bridge never pre-reads or pins it.
        let dataRoot = PersistenceCore.defaultDataRoot()
        let persona = port.activePersona(dataRoot: dataRoot)

        let client = port.chatClient()
        let started = Date()
        // Caller-supplied generic IDs correlate a lost response; they do not
        // deduplicate sends or authorize replay. Duplicate receipts fail closed.
        let requestID = (defaultSender == "agent" ? json["request_id"] as? String : nil) ?? UUID().uuidString
        // Publish: bridge received an inbound message (me → her).
        port.publishEvent(kind: "message_in", payload: [
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
        let ackMode = defaultSender == "agent" ? "enqueue" : (json["ackMode"] as? String)?.lowercased()
        // ---- Inbound peer lane: identity, replay, surface. ----
        //
        // Everything below this point on the `agent` lane runs as a REMOTE
        // PEER, never as the person. Three things follow from that, in order:
        // claim the protocol's own message id durably so a resend cannot run
        // the turn twice; run the turn on `agent-bridge` unless the person has
        // granted this exact peer elevation; and bind that surface as an
        // authoritative envelope so no gate can re-derive a friendlier one.
        var peerClaim: (store: AgentPeerReplayClaimStore, key: String, digest: String)?
        var turnSurface = "chat"
        var turnEnvelope: TurnEnvelope?
        let turnFileAccess = "auto"
        if defaultSender == "agent" {
            guard let peer else {
                writeProjectedMessage(response, projection: responseProjection, status: 500, obj: ["error": "peer_context_missing"])
                return
            }
            guard let key = peer.claimKey else {
                writeProjectedMessage(response, projection: responseProjection, status: 400, obj: [
                    "error": "request_id_required",
                    "detail": "Inbound peer messages carry a stable request_id/messageId so a resend is recognised rather than replayed.",
                ])
                return
            }
            let store = AgentPeerReplayClaimStore(dataRoot: PersistenceCore.defaultDataRoot())
            let outcome: AgentPeerReplayClaimStore.Outcome
            do { outcome = try store.claim(key: key, digest: peer.bodyDigest) }
            catch {
                writeProjectedMessage(response, projection: responseProjection, status: 500, obj: ["error": "replay_claim_unavailable"])
                return
            }
            switch outcome {
            case .claimed:
                peerClaim = (store, key, peer.bodyDigest)
            case .replay:
                // Identical bytes, identical id: the ORIGINAL receipt, and no
                // second row in the transcript.
                let cached = outcome.cachedReceipt ?? ["status": "ok", "ack": "replayed"]
                port.publishEvent(kind: "peer_message_replayed", payload: [
                    "protocol": peer.protocolName, "principal": peer.principal.id,
                ])
                writeProjectedMessage(response, projection: responseProjection, status: 200, obj: cached)
                return
            case .conflict:
                writeProjectedMessage(response, projection: responseProjection, status: 409, obj: [
                    "error": "message_id_reused",
                    "detail": "That message id was already used for different content. Send new content under a new id.",
                ])
                return
            case .inFlight:
                writeProjectedMessage(response, projection: responseProjection, status: 409, obj: [
                    "error": "message_in_flight",
                    "detail": "That message id is already being handled. Read its reply rather than resending.",
                ])
                return
            }
            turnSurface = peer.principal.surface
            if !peer.principal.elevated {
                // She knows who she is talking to before she says a word, and
                // that acting here asks the person first. 2026-09-15: this
                // replaces the old `read_only` clamp, which pre-empted the
                // permission card — a file write a peer asked for should reach
                // the person as a card, not die as a transport-level refusal.
                text = AgentBridgeSurface.turnHeader(
                    peerName: peer.principal.displayName,
                    elevated: false
                ) + text
            }
            turnEnvelope = TurnEnvelope(
                surface: turnSurface,
                agent: "peer",
                verifiedUserId: peer.principal.peerID,
                // The bridge bearer authenticates the PORT, not the caller; a
                // per-peer scoped credential is the only thing that attests
                // one. Honest nil is what keeps the gates fail-closed.
                commandSignatureVerified: peer.principal.peerID != nil,
                declaredRemote: !peer.principal.elevated
            )
        }
        if !isCodexCompletion, ackMode == "enqueue" || ackMode == "enqueue_only" {
            // The receipt this lane answers with IS the replay answer.
            var onReceipt: (@Sendable ([String: Any]) -> Void)?
            var onFailure: (@Sendable () -> Void)?
            if let claim = peerClaim {
                let store = claim.store, key = claim.key, digest = claim.digest
                onReceipt = { receipt in store.recordReceipt(key: key, digest: digest, receipt: receipt) }
                onFailure = { store.release(key: key) }
            }
            handleMessageAckOnEnqueue(
                response: response,
                client: client,
                surface: turnSurface,
                envelope: turnEnvelope,
                fileAccess: turnFileAccess,
                onReceipt: onReceipt,
                onFailure: onFailure,
                // 2026-09-06: this lane used to drop `image_paths` on the
                // floor — attachments and their skip note reached the legacy
                // lane only, so an enqueued studio consult arrived with a
                // header and no pixels.
                text: Self.withImageSkipNote(text, imageSkips),
                attachments: attachments,
                sessionId: sessionId,
                persona: persona,
                origin: origin,
                claudeReplyID: claudeReplyID,
                claudeReplyText: rawText,
                requestID: requestID,
                started: started,
                runTurn: ackMode != "enqueue_only",
                responseProjection: responseProjection
            )
            return
        }
        // U5 W-G: bound the work phase. The latch makes the work Task and the
        // deadline timer race for the single response write; the loser no-ops.
        let progress = chatNoticeSink(requestID: requestID, sessionID: sessionId)
        let bridgeTurnMessage = Self.withImageSkipNote(text, imageSkips)
        let workLatch = port.makeResponseLatch()
        _ = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lifecycleClaimed = false
            var responseCached = false
            do {
                let resp: ChatOrchestration.ChatResponse
                var wasCached = false
                if let deliveryId, let completionRequestDigest {
                    switch try await CodexCompletionLifecycle.shared.claim(
                        deliveryId: deliveryId,
                        requestDigest: completionRequestDigest,
                        sessionId: sessionId
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
                        self.writeProjectedMessage(response, projection: responseProjection, status: 200, obj: object)
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
                        let request = TurnRequest(
                            message: bridgeTurnMessage,
                            sessionID: sessionId,
                            attachments: attachments,
                            persona: persona,
                            // Keep local bridge trust semantics. The reply
                            // route carries only the immutable reply
                            // destination for async follow-up work.
                            surface: "chat",
                            replyRoute: completionRoute?.chatToolReplyRoute,
                            origin: origin,
                            codexCompletion: CodexCompletionTranscriptBinding(
                                deliveryId: deliveryId,
                                requestDigest: completionRequestDigest,
                                // Canonical assistant persistence replaces
                                // these placeholders with executed truth.
                                model: "",
                                reasoningEffort: nil
                            )
                        )
                        let generated = try await TurnAdmission.shared.run(sessionID: sessionId) {
                            try await request.chat(on: client, progress: progress)
                        }
                        // The full Agent response is canonical before any external
                        // surface send begins. A retry/relaunch now resumes delivery
                        // from this cache and can never start a second model turn.
                        try await CodexCompletionLifecycle.shared.cacheResponse(
                            generated,
                            deliveryId: deliveryId,
                            requestDigest: completionRequestDigest
                        )
                        responseCached = true
                        resp = generated
                    case .inProgress:
                        guard workLatch.claim() else { return }
                        self.writeProjectedMessage(response, projection: responseProjection, status: 202, obj: [
                            "status": "completion_in_progress",
                            "deliveryId": deliveryId,
                        ])
                        return
                    case .outcomeUnknown:
                        guard workLatch.claim() else { return }
                        self.writeProjectedMessage(response, projection: responseProjection, status: 409, obj: [
                            "status": "outcome_unknown",
                            "error": "completion_claim_interrupted",
                            "deliveryId": deliveryId,
                        ])
                        return
                    case .conflict:
                        guard workLatch.claim() else { return }
                        self.writeProjectedMessage(response, projection: responseProjection, status: 409, obj: [
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
                    let request = TurnRequest(message: bridgeTurnMessage, sessionID: sessionId, attachments: attachments,
                                              persona: persona, surface: "chat", origin: origin)
                    resp = try await TurnAdmission.shared.run(sessionID: sessionId) {
                        try await request.chat(on: client, progress: progress)
                    }
                }
                await self.port.publishChatTurnCompleted(sessionID: resp.sessionId ?? sessionId)
                if let claudeReplyID {
                    Self.recordClaudeReply(to: claudeReplyID, text: rawText, sessionId: resp.sessionId ?? sessionId)
                }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let trimmedReply = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentPayload = Self.bridgeAttachmentPayload(resp.attachments)
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
                ]
                if let deliveryId { persistedReply["deliveryId"] = deliveryId }
                if let completionDelivery {
                    persistedReply["completionDelivery"] = completionDelivery.jsonObject
                }
                Self.persistMessageReply(persistedReply, requestID: requestID)
                // Publish: bridge got the reply (her → me).
                self.port.publishEvent(kind: "message_out", payload: [
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
                ]
                if let deliveryId { responseObject["deliveryId"] = deliveryId }
                if let completionDelivery {
                    responseObject["completionDelivery"] = completionDelivery.jsonObject
                }
                self.writeProjectedMessage(response, projection: responseProjection, status: 200, obj: responseObject)
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
                self.writeProjectedMessage(response, projection: responseProjection, status: retryable ? 429 : 503, obj: [
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
                self.writeProjectedMessage(response, projection: responseProjection, status: 200, obj: cancelObject)
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
                ], requestID: requestID)
                self.port.publishEvent(kind: "message_failed", payload: [
                    "requestId": requestID,
                    "sessionId": sessionId ?? NSNull(),
                    "detail": failureDetail,
                    "status": failureStatus,
                ])
                guard workLatch.claim() else { return }
                self.writeProjectedMessage(response, projection: responseProjection, status: failureStatus == "outcome_unknown" ? 409 : 500, obj: [
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
            self.port.publishEvent(kind: "message_deadline_released", payload: [
                "requestId": requestID,
                "seconds": Self.messageWorkDeadlineSeconds,
                "sessionId": sessionId ?? NSNull(),
            ])
            var pending = Self.pendingMessageReply(
                requestID: requestID, sessionID: sessionId
            )
            if defaultSender == "agent" {
                pending["replyReceipt"] = ["route": "/agent/reply", "method": "POST",
                    "request_id": requestID, "session_id": sessionId as Any? ?? NSNull()]
                pending["detail"] = "The HTTP wait ended without cancelling the original turn. Recover its eventual receipt using the same request and session IDs; absence does not authorize resending."
            }
            self.writeProjectedMessage(response, projection: responseProjection, status: 202, obj: pending)
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
    public static func agentReplyReceipt(requestID: String, sessionID: String, offset: Int = 0,
                                  maxChars: Int = 8000, logURL: URL) -> [String: Any] {
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
        /// The turn's surface. "chat" for Claude's own lane (unchanged);
        /// "agent-bridge" for an unelevated inbound peer.
        surface: String = "chat",
        /// Bound as the AUTHORITATIVE per-turn envelope when present, so the
        /// gates cannot recompose a friendlier surface from task-locals.
        envelope: TurnEnvelope? = nil,
        fileAccess: String = "auto",
        /// Called with the receipt this lane answered with, for the replay
        /// claim. Called at most once.
        onReceipt: (@Sendable ([String: Any]) -> Void)? = nil,
        /// Called when the turn never reached a receipt, so an honest retry is
        /// not answered forever with "in flight".
        onFailure: (@Sendable () -> Void)? = nil,
        text: String,
        attachments: [ChatOrchestration.MultimodalAttachment],
        sessionId: String?,
        persona: String?,
        origin: ChatMessageOrigin,
        claudeReplyID: String?,
        claudeReplyText: String,
        requestID: String,
        started: Date,
        /// false = notice delivery: append the row, answer the ack, run NO
        /// turn. The row is ordinary transcript history the agent reads on its
        /// next real turn; it starts no decision and loads no tools.
        runTurn: Bool = true,
        responseProjection: (@Sendable (Int, [String: Any]) -> [String: Any])? = nil
    ) {
        let enqueueLatch = port.makeResponseLatch()
        // 2026-09-06: the enqueued row is the ONLY durable user message on
        // this lane — the turn below runs with suppressUserAppend, so images
        // that reached the model left no trace in the transcript at all.
        let request = TurnRequest(message: text, sessionID: sessionId, fileAccess: fileAccess, attachments: attachments,
                                  persona: persona, surface: surface, envelope: envelope, origin: origin)
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
                    mechanicalRow: runTurn ? nil : .transportNotice
                )
            } catch {
                onFailure?()
                guard enqueueLatch.claim() else { return }
                self.port.publishEvent(kind: "message_enqueue_failed", payload: [
                    "detail": String(describing: error),
                    "sessionId": sessionId ?? NSNull(),
                ])
                self.writeProjectedMessage(response, projection: responseProjection, status: 500, obj: [
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
                onFailure?()
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
            // Recorded BEFORE the answer goes out, so a resend that races the
            // response still meets a claim that can answer it.
            onReceipt?(receipt)
            self.writeProjectedMessage(response, projection: responseProjection, status: 200, obj: receipt)
            self.port.publishEvent(kind: "message_enqueued", payload: [
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
                let turn = request.consuming(enqueued)
                let resp = try await TurnAdmission.shared.run(sessionID: enqueued.sessionId) {
                    try await turn.chat(on: client, progress: self.chatNoticeSink(
                        requestID: requestID,
                        sessionID: enqueued.sessionId,
                        runID: enqueued.runId
                    ))
                }
                await self.port.publishChatTurnCompleted(sessionID: resp.sessionId ?? enqueued.sessionId)
                if let claudeReplyID {
                    Self.recordClaudeReply(to: claudeReplyID, text: claudeReplyText, sessionId: resp.sessionId ?? enqueued.sessionId)
                }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let trimmedReply = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentPayload = Self.bridgeAttachmentPayload(resp.attachments)
                let replyStatus = Self.codexCompletionReplyStatus(
                    hasReplyText: !trimmedReply.isEmpty,
                    attachmentCount: attachmentPayload.count,
                    completionDeliveryStatus: nil
                )
                Self.persistMessageReply([
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "status": replyStatus,
                    "ack": "enqueued",
                    "sessionId": resp.sessionId ?? enqueued.sessionId,
                    "model": resp.model,
                    "runId": resp.runId,
                    "durationMs": durationMs,
                    "reply": resp.output,
                    "attachments": attachmentPayload,
                ], requestID: requestID)
                self.port.publishEvent(kind: "message_out", payload: [
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
                // DELIVERY HAS SETTLED HERE, not when `client.chat` returned
                // (Astra comb 3, lane1 finding 1, 2026-09-12): the reply row is
                // on disk and `message_out` is published. Only now drain the
                // after-turn memory promotion, so its seconds land behind the
                // consumer instead of in front of it.
                await client.drainDeferredMemoryPromotion()
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
                ], requestID: requestID)
                self.port.publishEvent(kind: "message_failed", payload: [
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
                ], requestID: requestID)
                self.port.publishEvent(kind: "message_failed", payload: [
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
            self.port.publishEvent(kind: "message_enqueue_timeout", payload: [
                "seconds": Self.enqueueAckDeadlineSeconds,
                "sessionId": sessionId ?? NSNull(),
            ])
            self.writeProjectedMessage(response, projection: responseProjection, status: 504, obj: [
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

    static func codexCompletionRequestDigest(_ json: [String: Any]) -> String? {
        var canonical: [String: Any] = [:]
        for key in ["text", "sessionId", "origin", "completion"] {
            if let value = json[key] { canonical[key] = value }
        }
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
        hasReplyText: Bool,
        attachmentCount: Int,
        completionDeliveryStatus: String?
    ) -> String {
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

    /// 2026-09-22: a live Claude answers Agent in a bridge chat, never in the
    /// wake job, so her delegations all read unanswered. A `reply_to` naming a
    /// real inbox message is recorded beside that inbox for the projection.
    static func validClaudeReplyID(_ messageID: String) -> String? {
        let dir = messageReplyURL().deletingLastPathComponent()
        guard !messageID.isEmpty, messageID.utf8.count <= 128,
              !DelegationStatusProjector.requestTexts(inbox: dir.appendingPathComponent("claude-inbox.jsonl"),
                                                      ids: [messageID], field: "messageId").isEmpty else { return nil }
        return messageID
    }

    /// The send Claude's message answers, only when she says which: an exact
    /// inbox messageId (`reply_to` / `in_reply_to`), or the conversation it
    /// continues (`conversation_id`, her claude:<topic> handle) resolved to the
    /// send waiting there. A message naming neither answers nothing; it is
    /// Claude starting a chat of her own.
    static func claudeReplyID(_ json: [String: Any]) -> String? {
        if let named = (json["reply_to"] ?? json["in_reply_to"]) as? String, !named.isEmpty {
            return validClaudeReplyID(named)
        }
        guard let conversation = json["conversation_id"] as? String, !conversation.isEmpty, conversation.utf8.count <= 512
        else { return nil }
        return (try? AgentConversationStore(dataRoot: PersistenceCore.defaultDataRoot())
            .waitingMessage(agent: "claude", conversationID: conversation)).flatMap(validClaudeReplyID)
    }

    /// After the reply is durably in the chat: the receipt the delegation
    /// projection joins, and the answered send's conversation record settles.
    static func recordClaudeReply(to messageID: String, text: String, sessionId: String?) {
        _ = try? AgentConversationStore(dataRoot: PersistenceCore.defaultDataRoot())
            .settleReply(agent: "claude", messageID: messageID, text: text)
        let dir = messageReplyURL().deletingLastPathComponent()
        let row: [String: Any] = [
            "messageId": messageID, "sessionId": sessionId ?? NSNull(),
            "replyTextHead": text.count > 400 ? String(text.prefix(399)) + "…" : text,
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

    private static func persistMessageReply(_ payload: [String: Any], requestID: String) {
        messageReplyLock.lock()
        defer { messageReplyLock.unlock() }
        let payload = messageReplyRecord(payload, requestID: requestID)
        let file = messageReplyURL()
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
                NSLog("[ClaudeBridge] message-reply persist skipped: payload not JSON-serializable")
                return
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
                NSLog(
                    "[ClaudeBridge] message-replies cap dropped %d oldest row(s)",
                    dropped
                )
            }
        } catch {
            NSLog("[ClaudeBridge] message-reply persist failed: %@", String(describing: error))
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
            self?.port.publishEvent(kind: "message_notice", payload: [
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
