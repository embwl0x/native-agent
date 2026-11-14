import Foundation
import Experiences
import NativeAgentShared
import CoreFoundation
import Network
import AgentWorkspace
import AgentConversations
import AgentLinkTransport
import ChatToolRuntime
import NativeAgentCore
import PersistenceCore
import Privacy
// Blueprint: | `AgentContactRoutes.swift` | Authenticated ingress shares retained task ownership. |

private final class AgentContactHTTPWait: @unchecked Sendable {
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var cancelled = false

    func start(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard !cancelled, worker == nil else { return }
            worker = Task {
                defer { self.lock.withLock { self.worker = nil } }
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true; worker?.cancel() }
    }
}

public struct AgentContactRoutes: Sendable {
    private let token: @Sendable () -> String
    private let port: @Sendable () -> UInt16
    private let grpcPort: @Sendable () -> UInt16?
    private let tasks: @Sendable () -> AgentContactTasks
    private let receiveGrok: @Sendable (GrokReplyInput, AgentBridgePrincipal, URL) async throws -> Void

    public init(token: @escaping @Sendable () -> String,
                port: @escaping @Sendable () -> UInt16,
                grpcPort: @escaping @Sendable () -> UInt16?,
                tasks: @escaping @Sendable () -> AgentContactTasks,
                receiveGrok: @escaping @Sendable (GrokReplyInput, AgentBridgePrincipal, URL) async throws -> Void) {
        self.token = token
        self.port = port
        self.grpcPort = grpcPort
        self.tasks = tasks
        self.receiveGrok = receiveGrok
    }

    static let contactPaths: Set<String> = ["/agent/grok-reply", "/agent/mcp", "/.well-known/agent-card.json", "/a2a", "/agent/card", "/agent/reply",
        "/agent/message"]
    public static func isContactPath(_ path: String) -> Bool {
        contactPaths.contains(path) || path.hasPrefix("/a2a/")
    }

    /// Peer bearers admit contacts; explicit identity headers still require the listener bearer.
    public static func admit(headers: [String: String], liveToken: String,
                               dataRoot: URL,
                               readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> (BridgeAuthDecision,
                                   AgentBridgePrincipal) {
        guard !liveToken.isEmpty else { return (.serverStopping, .anonymous) }
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: dataRoot, readCredential: readCredential)
        let decision: BridgeAuthDecision = !AgentBridgePrincipal.claimsIdentity(headers: headers) && principal.peerID != nil
            ? .authorized : BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: liveToken)
        return (decision, principal)
    }

    public static func mcpTransportRejection(headers: [String: String], port: UInt16) -> Int? {
        if let origin = headers["origin"], origin != "http://127.0.0.1:\(port)" { return 403 }
        if let version = headers["mcp-protocol-version"], !NativeAgentMCPWire.versions.contains(version) { return 400 }
        let accept = Set((headers["accept"] ?? "").lowercased().split(separator: ",").compactMap {
            $0.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
        })
        guard accept.contains("application/json"), accept.contains("text/event-stream") else { return 406 }
        guard headers["content-type"]?.lowercased().split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) == "application/json" else { return 415 }
        return nil
    }

    public func route(conn: NWConnection, method: String, path: String,
                      headers: [String: String], body: Data, dataRoot: URL) -> Bool {
        guard Self.isContactPath(path) else {
            return false
        }
        let (admission, principal) = Self.admit(headers: headers, liveToken: token(), dataRoot: dataRoot)
        switch admission {
        case .serverStopping:
            BridgeCore.writeJSON(conn, status: 503, obj: ["error": "server_stopping"])
            return true
        case .unauthorized:
            BridgeCore.writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return true
        case .authorized:
            break
        }
        var handled = true
        func routeContact() {
        // Reject revoked or unknown contact credentials before routing; the listener bearer alone cannot excuse them.
        if principal.peerID == nil {
            BridgeCore.writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        }
        if let peerID = principal.peerID { AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peerID, inbound: true) }

        let isGrok = principal.replyOnly
        // A verified routine bearer uses the same peer messaging and Trust boundaries as other contacts; it grants no A2A or tool access.
        if path == "/agent/grok-reply" || (isGrok && path != "/agent/mcp") {
            guard isGrok, path == "/agent/grok-reply", method == "POST", body.count <= GrokReplyInput.maximumBytes else {
                BridgeCore.writeJSON(conn, status: 403, obj: ["error": "reply_scope_only"])
                return
            }
            Task {
                do {
                    try await receiveGrok(GrokReplyInput.parse(body), principal, dataRoot)
                    BridgeCore.writeJSON(conn, status: 200, obj: ["status": "answered"])
                } catch {
                    BridgeCore.writeJSON(conn, status: 409, obj: ["error": "unknown_expired_or_already_answered_message"])
                }
            }
            return
        }

        if path == "/a2a/notifications" {
            guard method == "POST", body.count <= 256 * 1024 else {
                Self.writeA2AJSON(conn, status: 400, object: ["error": "Invalid notification request"])
                return
            }
            Task {
                do {
                    let value = try JSONDecoder().decode(JSONValue.self, from: body)
                    try await AgentA2APushReceiver.shared.receive(value: value, peerID: principal.id)
                    Self.writeA2AJSON(conn, status: 200, object: [:])
                } catch {
                    Self.writeA2AJSON(conn, status: 400, object: ["error": "Invalid A2A notification"])
                }
            }
            return
        }
        if path.hasPrefix("/a2a/") {
            Self.request(conn) {
                let endpoint = AgentContactA2AEndpoint(tasks: self.tasks(), port: port(),
                    grpcPort: grpcPort())
                let response = await endpoint.handleREST(method: method, target: path, body: body,
                        principal: principal, version: headers["a2a-version"])
                guard !Task.isCancelled else { response.failed(); return }
                switch response {
                case .json(let status, let value, let onSent, let onFailed):
                    Self.writeA2AJSON(conn, status: status, object: value, onSent: { Task { await onSent?() } }, onFailed: onFailed)
                case .stream(let events, let metadata, let onSent, let settle):
                    AgentContactSSE.write(conn, id: "rest", events: events, version: "1.0", rest: true,
                        metadata: metadata, onSent: onSent, settle: settle)
                }
            }
            return
        }

        switch path {
        case "/agent/mcp":
            if let origin = headers["origin"], origin != "http://127.0.0.1:\(port())" {
                BridgeCore.writeJSON(conn, status: 403, obj: ["error": "unsupported_mcp_origin"])
                return
            }
            guard method == "POST" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            if let rejection = Self.mcpTransportRejection(headers: headers, port: port()) {
                BridgeCore.writeJSON(conn, status: rejection, obj: ["error": "unsupported_mcp_transport_headers"])
                return
            }
            // The caller this connector names is the conversation the call is in; a door that names none calls in the contact's own.
            let caller: ContactCaller?
            do { caller = try headers[ContactCaller.header].map(ContactCaller.init(header:)) }
            catch {
                BridgeCore.writeJSON(conn, status: 400, obj: ["error": "invalid_caller_header", "detail": error.localizedDescription])
                return
            }
            // Settle drained pull-host messages only after their response is written; failed responses leave them held.
            let conversations = AgentConversationStore(dataRoot: dataRoot)
            let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let tool = request?["method"] as? String == "tools/call" ? (request?["params"] as? [String: Any])?["name"] as? String : nil
            let session = principal.peerID.map { peer in caller?.conversation(peer: peer) ?? AgentConversationStore.heldThread(peerID: peer) } ?? ""
            func wire(_ item: AgentConversationStore.Held) -> [String: String] {
                ["at": NativeTimestampFormat.plainZulu(item.at), "text": item.text, "conversation_id": item.conversation ?? session,
                 "conversation_name": item.name]
            }
            let held: AgentConversationStore.HeldDrain
            do {
                if let tool, let peer = principal.peerID {
                    held = try conversations.drainHeld(peer: peer, conversation: session, name: principal.displayName ?? principal.id, via: tool) {
                        NativeAgentMCPWire.heldFits($0.map(wire))
                    }
                } else { held = .nothing }
            } catch {
                BridgeCore.writeJSON(conn, status: 503, obj: ["error": "held_message_drain_failed",
                    "source": conversations.fileURL.path,
                    "detail": NativeAgentSecretRedactor.redactText(error.localizedDescription)])
                return
            }
            let taken = held.taken
            let settle = held.settle
            switch NativeAgentMCPWire.parse(request, byteCount: body.count, defaultSession: session,
                                            held: (taken.map(wire), held.remaining)) {
            case .message(let message, let replayBody, let wait, let project):
                // SSE requires the relay's explicit read capability.
                let mcpWait = (seconds: wait.seconds,
                               progressToken: headers["x-nativeagent-relay-sse"] == "1" ? wait.progressToken : nil)
                handleContactMessage(conn: conn, json: message, tasks: self.tasks(),
                              peer: peerTurnContext(principal: principal, protocolName: "mcp",
                                                    // Digest the message, not its JSON-RPC envelope, because retries may change envelope IDs.
                                                    requestBody: replayBody),
                              responseProjection: project, mcpWait: mcpWait, settle: settle)
            case .reply(let request, let session, let offset, let waitSeconds, let artifactID, let project):
                Task {
                    let tasks = self.tasks()
                    let reply = await peerReplyReceipt(requestID: request, sessionID: session,
                        offset: artifactID == nil ? offset : 0, waitSeconds: waitSeconds, principal: principal, tasks: tasks)
                    let response = project(reply.receipt)
                    let fetched = NativeAgentMCPWire.carriesReply(response) ? Self.fetched(reply.receipt, task: reply.task, tasks: tasks) : nil
                    let carriedHeld = response["error"] == nil
                    BridgeCore.writeJSON(conn, status: 200, obj: response, onSent: { fetched?(); settle(carriedHeld) },
                                         onFailed: { settle(false) })
                }
            case .table(let arguments, let project):
                Task {
                    let read = await Self.tableRead(arguments, principal: principal, dataRoot: dataRoot)
                    let response = project(read.fields, read.failed)
                    let carriedHeld = response["error"] == nil
                    BridgeCore.writeJSON(conn, status: 200, obj: response, onSent: { settle(carriedHeld) }, onFailed: { settle(false) })
                }
            case .immediate(let status, let response):
                settle(false)
                BridgeCore.writeJSON(conn, status: status, obj: response)
            case .acceptedNotification:
                settle(false)
                conn.send(content: Data("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        case "/.well-known/agent-card.json":
            guard method == "GET" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            let cardVersion = headers["a2a-version"]?.hasPrefix("0.3") == true ? "0.3" : "1.0"
            BridgeCore.writeJSON(conn, status: 200, obj: NativeAgentA2AWire.card(port: port(), version: cardVersion,
                grpcPort: grpcPort()))
        case "/a2a":
            guard method == "POST" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            Self.request(conn) {
                let response = await AgentContactA2AEndpoint(tasks: self.tasks(), port: port(),
                    grpcPort: grpcPort())
                    .handle(try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]), byteCount: body.count, principal: principal,
                        version: headers["a2a-version"])
                guard !Task.isCancelled else { response.failed(); return }
                switch response {
                case .json(let object, let onSent, let onFailed):
                    BridgeCore.writeJSON(conn, status: 200, obj: object, onSent: { Task { await onSent?() } }, onFailed: onFailed)
                case .stream(let id, let events, let version, let metadata, let onSent, let settle):
                    AgentContactSSE.write(conn, id: id, events: events, version: version,
                        metadata: metadata, onSent: onSent, settle: settle)
                }
            }
        case "/agent/card":
            guard method == "GET" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            BridgeCore.writeJSON(conn, status: 200, obj: Self.agentPeerCard())
        case "/agent/reply":
            guard method == "POST" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let requestID = json["request_id"] as? String,
                  let sessionID = json["session_id"] as? String else {
                BridgeCore.writeJSON(conn, status: 400, obj: ["error": "request_id_and_session_id_required"])
                return
            }
            guard (json["offset"] == nil || Self.peerInteger(json["offset"]) != nil),
                  (json["max_chars"] == nil || Self.peerInteger(json["max_chars"]) != nil) else {
                BridgeCore.writeJSON(conn, status: 400, obj: ["error": "invalid_pagination"])
                return
            }
            Task {
                let tasks = self.tasks()
                let result = await peerReplyReceipt(requestID: requestID, sessionID: sessionID,
                    offset: Self.peerInteger(json["offset"]) ?? 0, maxChars: Self.peerInteger(json["max_chars"]) ?? 8000,
                    principal: principal, tasks: tasks)
                do {
                    let held = try AgentContactHeldResponse(principal: principal, dataRoot: dataRoot, via: "/agent/reply")
                    let fetched = Self.fetched(result.receipt, task: result.task, tasks: tasks)
                    BridgeCore.writeJSON(conn, status: result.receipt["status"] as? String == "invalid_request" ? 400 : 200,
                        obj: held.adding(to: result.receipt), onSent: { fetched?(); held.settle(true) }, onFailed: { held.settle(false) })
                } catch {
                    BridgeCore.writeJSON(conn, status: 503, obj: AgentContactHeldResponse.failure(error, dataRoot: dataRoot))
                }
            }
        case "/agent/message":
            guard method == "POST" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            do {
                let held = try AgentContactHeldResponse(principal: principal, dataRoot: dataRoot, via: "/agent/message")
                handleContactMessage(conn: conn, json: json, tasks: self.tasks(),
                    peer: peerTurnContext(principal: principal, protocolName: "agent-message", requestBody: body), held: held)
            } catch {
                BridgeCore.writeJSON(conn, status: 503, obj: AgentContactHeldResponse.failure(error, dataRoot: dataRoot))
            }
        default:
            handled = false
        }
        }
        routeContact()
        return handled
    }

    /// The connection owns only its HTTP wait. Canceling it never calls the retained task's explicit cancel operation or owns the canonical turn. Receive EOF
    /// is a half-close: the peer can still read the whole reply.
    private static func request(_ conn: NWConnection, operation: @escaping @Sendable () async -> Void) {
        let wait = AgentContactHTTPWait()
        let previous = conn.stateUpdateHandler
        conn.stateUpdateHandler = { state in
            previous?(state)
            switch state {
            case .failed, .cancelled: wait.cancel()
            default: break
            }
        }
        switch conn.state {
        case .failed, .cancelled: wait.cancel()
        default: break
        }
        wait.start(operation)
    }

    typealias PeerTurnContext = ClaudeBridgeMessageRuntime.PeerTurnContext

    private func peerTurnContext(principal: AgentBridgePrincipal, protocolName: String,
                                 requestBody: Data) -> PeerTurnContext {
        PeerTurnContext(
                        principal: principal,
            protocolName: protocolName,
            // Digest original request bytes because projected A2A requests mint a different server ID on each send.
            bodyDigest: AgentPeerReplayClaimStore.digest(requestBody)
        )
    }

    static func agentPeerCard() -> [String: Any] {
        ["protocol": "nativeagent-bridge", "version": "1.0", "name": "NativeAgent",
         "authentication": ["scheme": "bearer", "required": true],
         "message": ["method": "POST", "path": "/agent/message", "text_field": "text", "session_field": "sessionId",
                     "request_field": "request_id", "delivery": "durable_enqueue", "omitted_session": "contact_conversation"],
         "reply": ["method": "POST", "path": "/agent/reply", "request_field": "request_id", "session_field": "session_id", "maximum_chars": 16000],
         "authorship": "agent", "surface": "agent-bridge"]
    }

    private func peerReplyReceipt(requestID: String, sessionID: String, offset: Int = 0, maxChars: Int = 8000,
                                  waitSeconds: Int = 0, principal: AgentBridgePrincipal, tasks: AgentContactTasks) async -> (receipt: [String: Any],
                                      task: AgentContactTask?) {
        let protocolSession = NativeAgentMCPWire.validSession(sessionID) || NativeAgentA2AWire.validContext(sessionID)
        let storedSession = protocolSession ? principal.storedConversation(sessionID) : sessionID
        // Protocol context locates the task; the contact’s canonical session owns its turn.
        let taskID = Self.taskID(requestID: requestID, sessionID: sessionID, principal: principal)
        // Wait only to settlement or the caller’s bound; inability to observe the reply must be explicit.
        if waitSeconds > 0 {
            do {
                let events = try await tasks.subscribe(taskID, owner: principal.id)
                await Self.untilSettled(seconds: waitSeconds) {
                    for await event in events { if case .status(_, final: true) = event { return } }
                }
            } catch {
                return (["status": "unavailable", "retrieval_result_class": "failed", "evidence": "canonical_task_wait_unavailable",
                    "request_id": requestID, "session_id": sessionID,
                    "detail": """
                        The retained task could not be watched: \(error.localizedDescription). Repair task observation; do not repeat the message.
                        """], nil)
            }
        }
        return await Self.retainedReply(requestID: requestID, sessionID: sessionID,
            taskID: taskID, receiptSessionID: storedSession, offset: offset, maxChars: maxChars,
            principal: principal, tasks: tasks)
    }

    static func taskID(requestID: String, sessionID: String, principal: AgentBridgePrincipal) -> String {
        let protocolSession = NativeAgentMCPWire.validSession(sessionID) || NativeAgentA2AWire.validContext(sessionID)
        let prefix = AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)
        let context = !protocolSession && sessionID.hasPrefix(prefix) ? String(sessionID.dropFirst(prefix.count)) : sessionID
        return "na3.\(context).\(requestID)"
    }

    static func retainedReply(requestID: String, sessionID: String, taskID: String, receiptSessionID: String,
                              offset: Int, maxChars: Int, principal: AgentBridgePrincipal,
                                      tasks: AgentContactTasks) async -> (receipt: [String: Any], task: AgentContactTask?) {
        do {
            let task = try await tasks.get(taskID, owner: principal.id)
            return (contactReply(task, requestID: requestID, sessionID: sessionID, offset: offset, maxChars: maxChars), task)
        } catch let failure as AgentContactFailure where failure.isMissing {
            var receipt = ClaudeBridgeMessageRuntime.agentReplyReceipt(requestID: requestID, sessionID: receiptSessionID,
                offset: offset, maxChars: maxChars, logURL: ClaudeBridgeMessageRuntime.messageReplyURL(), principal: principal.id)
            if receipt["session_id"] as? String == receiptSessionID { receipt["session_id"] = sessionID }
            return (receipt, nil)
        } catch {
            let detail = (error as? AgentContactFailure)?.message ?? error.localizedDescription
            return (["status": "unavailable", "retrieval_result_class": "failed", "evidence": "canonical_task_unreadable",
                "detail": "Retained task or conversation could not be read: \(detail). Preserve the saved evidence; do not resend automatically."], nil)
        }
    }

    static func carriesReply(_ receipt: [String: Any]) -> Bool {
        (receipt["reply"] as? String)?.isEmpty == false
            || (receipt["attachments"] as? [[String: Any]])?.isEmpty == false
    }

    static func fetched(_ receipt: [String: Any], task: AgentContactTask?,
                                tasks: AgentContactTasks) -> (@Sendable () -> Void)? {
        guard let task, carriesReply(receipt) else { return nil }
        return { Task { await tasks.recordReplyFetch(task) } }
    }

    /// Peer and builder doors must share one retained execution owner.
    private func handleContactMessage(conn: NWConnection, json: [String: Any]?,
                                      tasks: AgentContactTasks, peer: PeerTurnContext,
                                      responseProjection: (@Sendable (Int, [String: Any]) -> [String: Any])? = nil,
                                      mcpWait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?)? = nil,
                                      held: AgentContactHeldResponse? = nil,
                                      settle: (@Sendable (Bool) -> Void)? = nil) {
        let settle = held?.settle ?? settle
        func reply(_ status: Int, _ object: [String: Any]) {
            let response = responseProjection?(status, object) ?? held?.adding(to: object) ?? object
            let carriedHeld = responseProjection == nil || response["error"] == nil
            BridgeCore.writeJSON(conn, status: responseProjection == nil ? status : 200,
                      obj: response, onSent: { settle?(carriedHeld) }, onFailed: { settle?(false) })
        }
        guard let json,
              ClaudeBridgeMessageRuntime.validGenericAgentMessage(json), let text = json["text"] as? String else {
            reply(400, ["status": "rejected", "detail": "The message is invalid. Work: nothing ran."]); return
        }
        let principal = peer.principal
        let requested = json["sessionId"] as? String
        let protocolSession = peer.protocolName == "mcp"
        let prefix = AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)
        // MCP session IDs remain transport locators; a context runs in the conversation it names (AgentBridgePrincipal.storedConversation).
        let stored = protocolSession ? requested.map { prefix + $0 }
            : ClaudeBridgeMessageRuntime.genericAgentSessionID(requested: requested, owner: principal.id)
        guard let stored, stored.hasPrefix(prefix) else {
            reply(403, ["status": "rejected", "detail": "This conversation belongs to another contact. Work: nothing ran."]); return
        }
        let context = String(stored.dropFirst(prefix.count))
        let session = protocolSession ? context : stored
        let request = json["request_id"] as? String ?? UUID().uuidString
        let send = NativeAgentA2AWire.Send(rpcID: request, context: context, request: request,
            clientMessageID: request, parts: [.text(text)])
        Task {
            do {
                let task = try await tasks.send(send, principal: principal, digest: peer.bodyDigest, protocolName: peer.protocolName)
                let ack: [String: Any] = ["status": "ok", "ack": "enqueued", "requestId": request,
                    "sessionId": session, "task_id": task.id]
                guard let mcpWait, mcpWait.seconds > 0, let responseProjection else { reply(200, ack); return }
                await Self.writeWaitedReply(conn: conn, ack: ack, taskID: task.id, requestID: request, sessionID: session,
                    owner: principal.id, tasks: tasks, wait: mcpWait, project: responseProjection, settle: settle)
            } catch {
                reply(409, ["status": "rejected", "requestId": request, "sessionId": session,
                    "detail": (error as? AgentContactFailure)?.message ?? "The message could not be accepted. Work: outcome unknown."])
            }
        }
    }

    /// Hold the HTTP response until settlement or the caller’s bound to avoid polling. Progress tokens select SSE; ending either wait leaves the retained
    /// task, receipt and replay claim untouched.
    private static func writeWaitedReply(conn: NWConnection, ack: [String: Any], taskID: String, requestID: String,
                                         sessionID: String, owner: String, tasks: AgentContactTasks,
                                         wait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?),
                                         project: @escaping @Sendable (Int, [String: Any]) -> [String: Any],
                                         settle: (@Sendable (Bool) -> Void)?) async {
        // Whatever ended the wait, held messages it carried that were not written stay held.
        defer { settle?(false) }
        let ackData: Data
        do { ackData = try JSONSerialization.data(withJSONObject: ack) }
        catch {
            BridgeCore.writeJSON(conn, status: 500, obj: ["error": "acknowledgment_encoding_failed", "detail": error.localizedDescription])
            return
        }
        await writeWaitedReplyBody(conn: conn, ackData: ackData, taskID: taskID, requestID: requestID,
            sessionID: sessionID, owner: owner, tasks: tasks, wait: wait, project: project, settle: settle)
        conn.cancel()
    }

    private static func writeWaitedReplyBody(conn: NWConnection, ackData: Data, taskID: String, requestID: String,
                                             sessionID: String, owner: String, tasks: AgentContactTasks,
                                             wait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?),
                                             project: @escaping @Sendable (Int, [String: Any]) -> [String: Any],
                                             settle: (@Sendable (Bool) -> Void)?) async {
        let ack: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: ackData) as? [String: Any] else {
                throw AgentContactFailure(code: -32603, message: "The retained acknowledgment is not an object")
            }
            ack = object
        } catch {
            BridgeCore.writeJSON(conn, status: 500, obj: ["error": "acknowledgment_decoding_failed", "detail": error.localizedDescription])
            return
        }
        @Sendable func send(_ data: Data) async -> Bool {
            do { try await AgentContactSSE.send(data, on: conn); return true }
            catch { return false }
        }
        @Sendable func frame(_ object: [String: Any]) throws -> Data {
            var data = Data("event: message\ndata: ".utf8)
            data.append(try JSONSerialization.data(withJSONObject: object))
            data.append(Data("\n\n".utf8))
            return data
        }
        do {
        let token = wait.progressToken
        if token != nil, await !send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)) {
            conn.cancel(); return
        }
        var retrievalFailure: String?
        do {
            let events = try await tasks.subscribe(taskID, owner: owner)
            let agent = PeerFacingIdentity.agentName
            await untilSettled(seconds: wait.seconds) {
                var step = 0, last = Date.distantPast
                for await event in events {
                    let task: AgentContactTask
                    switch event {
                    case .status(let current, let final):
                        if final { return }
                        task = current
                    case .snapshot(let current), .artifact(let current, _, _, _, _): task = current
                    }
                    guard let token, Date().timeIntervalSince(last) >= 0.5 else { continue }
                    let message = task.state == .inputRequired ? (task.detail ?? "Waiting for the person")
                        : task.text.isEmpty ? "\(agent) is working" : String(task.text.suffix(2000))
                    last = Date(); step += 1
                    let progress: Data
                    do { progress = try frame(NativeAgentMCPWire.progress(token, step: step, message: message)) }
                    catch { nativeLog("Contact progress could not be encoded: %@", error.localizedDescription); conn.cancel(); return }
                    guard await send(progress) else { return }
                }
            }
        } catch { retrievalFailure = "The retained task could not be watched: " + error.localizedDescription }
        var receipt = ack
        var fetchedTask: AgentContactTask?
        if retrievalFailure == nil {
            do {
                let task = try await tasks.get(taskID, owner: owner)
                receipt.merge(contactReply(task, requestID: requestID, sessionID: sessionID, offset: 0, maxChars: 8000)) { ack, _ in ack }
                if carriesReply(receipt) { fetchedTask = task }
            } catch { retrievalFailure = "The retained task could not be read: " + error.localizedDescription }
        }
        if let retrievalFailure {
            receipt["status"] = "unavailable"
            receipt["retrieval_result_class"] = "failed"
            receipt["detail"] = retrievalFailure + ". The message remains accepted; repair task observation and do not resend it."
        }
        let response = project(200, receipt)
        let sent: Bool
        if token != nil {
            sent = await send(try frame(response))
        } else {
            let body = try JSONSerialization.data(withJSONObject: response)
            var data = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            data.append(body)
            sent = await send(data)
        }
        settle?(sent && response["error"] == nil)
        if sent, NativeAgentMCPWire.carriesReply(response), let fetchedTask { await tasks.recordReplyFetch(fetchedTask) }
        } catch { nativeLog("Contact result could not be encoded: %@", error.localizedDescription); conn.cancel() }
    }

    private static func untilSettled(seconds: Int, _ watch: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await watch() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    public static func contactReply(_ task: AgentContactTask, requestID: String, sessionID: String,
                             offset: Int, maxChars: Int) -> [String: Any] {
        let reply = task.state == .failed
            ? [task.text, task.detail ?? "The reply could not be completed. Work: outcome unknown."].filter { !$0.isEmpty }.joined(separator: "\n\n")
            : task.text
        guard offset >= 0, offset <= reply.count, (1...16000).contains(maxChars) else { return ["status": "invalid_request",
            "retrieval_result_class": "failed"] }
        let slice = String(reply.dropFirst(offset).prefix(maxChars))
        var receipt: [String: Any] = ["status": task.state.terminal ? "ok" : "pending",
            "retrieval_result_class": task.replyRecovery != nil ? "failed" : task.state.terminal ? "succeeded" : "unknown",
            "execution_result_class": task.state == .completed ? "succeeded" : task.state == .failed ? "failed" : task.state.terminal ? "cancelled" : "unknown",
            "execution_terminal": task.state.terminal,
            "original_status": task.state.rawValue, "request_id": requestID, "session_id": sessionID,
            "run_id": task.canonicalRunID ?? "", "reply": slice, "offset": offset,
            "next_offset": offset + slice.count, "has_more": offset + slice.count < reply.count]
        if let detail = task.detail { receipt["detail"] = detail }
        if let recovery = task.replyRecovery {
            receipt["reply_recovery"] = ["source": recovery.source, "detail": recovery.detail]
            receipt["detail"] = [task.detail, recovery.detail].compactMap { $0 }.joined(separator: "\n")
        }
        // Canonical file parts carry their bytes. Builder results additionally retain their door's attachment descriptors (including saved paths); return that
        // live payload at the same top-level keys its readers use.
        receipt["attachments"] = task.parts.enumerated().compactMap { index, part -> [String: Any]? in
            guard case .file(let name, let mediaType, let bytes, _) = part else { return nil }
            return ["id": "\(task.id):\(index)", "type": mediaType.hasPrefix("image/") ? "image" : "file",
                "mime": mediaType, "name": name, "byteSize": bytes.count,
                "base64": bytes.base64EncodedString(), "path": NSNull()]
        }
        if let result = task.toolResult {
            receipt["result"] = result.foundationObject
            if case .object(let fields) = result {
                for key in ["attachments", "completionDelivery", "deliveryId"] {
                    if let value = fields[key] { receipt[key] = value.foundationObject }
                }
            }
        }
        if let completions = task.delegatedCompletions {
            receipt["delegated_completions"] = completions.sorted { $0.key < $1.key }.map {
                var completion: [String: Any] = ["artifact_id": $0.key, "parts": [$0.value.wire03]]
                if case .text = $0.value {
                    completion["read_with"] = ["tool": "agent_reply", "arguments": ["session_id": sessionID, "request_id": $0.key]]
                }
                return completion
            }
        }
        if let failure = task.failure, let data = try? JSONEncoder().encode(failure),
           let object = try? JSONSerialization.jsonObject(with: data) {
            receipt["provider_failure"] = object
            receipt["work"] = failure.work.rawValue
        }
        return receipt
    }

    private static func peerInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

}


extension AgentContactRoutes {
    /// A contact the person brought to the table reads the Desk, or a piece on it; one not at the table is told how to get there. The lever is read
    /// again after the read, under the contact store's lock, by the same write that records the read on the contact: no lever or no record, no words.
    static func tableRead(_ arguments: [String: JSONValue], principal: AgentBridgePrincipal, dataRoot: URL) async -> (fields: [String: Any], failed: Bool) {
        let agent = PeerFacingIdentity.agentName
        let notAtTable: (fields: [String: Any], failed: Bool) = (["status": "not_at_table", "detail": """
            You are not at \(agent)'s table, so the Desk is not yours to read. Ask \(agent) with agent_message; \(agent) asks the person, \
            whose choice it is. Nothing was read.
            """], true)
        func project(_ value: JSONValue, failed: Bool) -> (fields: [String: Any], failed: Bool) {
            guard case .object(let fields) = value else { return (["result": value.foundationObject], failed) }
            return (fields.mapValues(\.foundationObject), failed)
        }
        func unknown(_ error: Error) -> (fields: [String: Any], failed: Bool) {
            (["status": "unavailable", "detail": """
                \(agent)'s contacts could not be read, so whether you are at the table is not known: \
                \(NativeAgentSecretRedactor.redactText(error.localizedDescription)). Nothing was read.
                """], true)
        }
        guard let peerID = principal.peerID else {
            return (["status": "refused", "detail": "Only a contact's own key reads the table. Nothing was read."], true)
        }
        let store = AgentPeerStore(dataRoot: dataRoot)
        let found: AgentPeerContact?
        do { found = try store.list().first { $0.id == peerID } }
        catch { return unknown(error) }
        // Only the person's lever, set on this contact, brings it to the table.
        guard let contact = found, contact.readsDesk == true, contact.canReadTable else { return notAtTable }
        let read: JSONValue
        do { read = try await SwiftToolDispatcher(dataRoot: dataRoot, allowProcessGlobalTools: false).tableRead(input: arguments) }
        catch {
            // A refusal carries no Desk words and is no read, but it goes back only while the contact is still at the table.
            do {
                guard let now = try store.list().first(where: { $0.id == peerID }), now.readsDesk == true, now.canReadTable else { return notAtTable }
            } catch { return unknown(error) }
            return project(ChatToolOutcome.failure(error: error, tool: "agent_desk", effects: ToolFailureError.Effects.none), failed: true)
        }
        let piece = read.objectValue?["piece"]?.objectValue
        let entry = AgentTableRead(at: Date(), piece: piece?["make_ref"]?.stringValue, title: piece?["title"]?.stringValue)
        do { guard try store.recordTableRead(peerID: peerID, entry) else { return notAtTable } }
        catch {
            return (["status": "unavailable", "detail": """
                The read could not be recorded on your contact (\(NativeAgentSecretRedactor.redactText(error.localizedDescription))), so its words \
                were not returned. Read again.
                """], true)
        }
        return project(read, failed: false)
    }

    static func writeA2AJSON(_ connection: NWConnection, status: Int, object: [String: Any], onSent: (@Sendable () -> Void)? = nil,
                             onFailed: (@Sendable () -> Void)? = nil) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            onFailed?(); connection.cancel(); return
        }
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 500 ? "Internal Server Error" : "Bad Request"))
        var bytes = Data("""
            HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/a2a+json\r\nCache-Control: no-store\r\nContent-Length: \
            \(body.count)\r\nConnection: close\r\n\r\n
            """.utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { error in
            if error == nil { onSent?() } else { onFailed?() }
            connection.cancel()
        })
    }
}

/// A response projection over the conversation owner's claim, never a second held-message store.
struct AgentContactHeldResponse: Sendable {
    private let drain: AgentConversationStore.HeldDrain
    private let conversation: String
    var settle: @Sendable (Bool) -> Void { drain.settle }

    /// These doors name no caller: they call in the contact's own conversation.
    init(principal: AgentBridgePrincipal, dataRoot: URL, via door: String) throws {
        let conversation = principal.conversationID(protocolName: "mcp") ?? ""
        self.conversation = conversation
        guard let peer = principal.peerID else { drain = .nothing; return }
        drain = try AgentConversationStore(dataRoot: dataRoot).drainHeld(peer: peer, conversation: conversation,
            name: principal.displayName ?? principal.id, via: door) {
            NativeAgentMCPWire.heldFits(Self.messages($0, conversation: conversation))
        }
    }

    private static func messages(_ items: [AgentConversationStore.Held], conversation: String) -> [[String: String]] {
        items.map { ["at": NativeTimestampFormat.plainZulu($0.at), "text": $0.text, "conversation_id": $0.conversation ?? conversation,
                     "conversation_name": $0.name] }
    }

    func adding(to object: [String: Any]) -> [String: Any] {
        guard !drain.taken.isEmpty || drain.remaining > 0 else { return object }
        var result = object
        result["held_messages"] = Self.messages(drain.taken, conversation: conversation)
        result["held_remaining"] = drain.remaining
        return result
    }

    var metadata: JSONValue {
        guard !drain.taken.isEmpty || drain.remaining > 0 else { return .object([:]) }
        return JSONValue(fromFoundation: ["nativeagent.held_messages": Self.messages(drain.taken, conversation: conversation),
            "nativeagent.held_remaining": drain.remaining])
    }

    static func failure(_ error: Error, dataRoot: URL) -> [String: Any] {
        ["error": "held_message_drain_failed", "source": AgentConversationStore(dataRoot: dataRoot).fileURL.path,
            "detail": NativeAgentSecretRedactor.redactText(error.localizedDescription)]
    }
}
