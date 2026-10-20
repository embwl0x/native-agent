import GrokLink
import Foundation
import CoreFoundation
import Network
import AgentWorkspace
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

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

    static let contactPaths: Set<String> = ["/agent/grok-reply", "/agent/mcp", "/.well-known/agent-card.json", "/a2a", "/agent/card", "/agent/reply", "/agent/message"]
    public static func isContactPath(_ path: String) -> Bool {
        contactPaths.contains(path) || path.hasPrefix("/a2a/")
    }

    /// Adapt the door's own bearer only for contact operations, never control routes.
    public static func contactHeaders(path: String, headers: [String: String], liveToken: String,
                               dataRoot: URL,
                               readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> [String: String] {
        guard isContactPath(path), !liveToken.isEmpty,
              !AgentBridgePrincipal.claimsIdentity(headers: headers),
              let id = AgentBridgePrincipal.resolve(headers: headers, dataRoot: dataRoot,
                  readCredential: readCredential).peerID,
              let authorization = headers["authorization"] else { return headers }
        var adapted = headers
        adapted[AgentBridgePrincipal.peerIDHeader] = id
        adapted[AgentBridgePrincipal.peerSecretHeader] = String(authorization.dropFirst(7))
        adapted["authorization"] = "Bearer " + liveToken
        return adapted
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
        let headers = Self.contactHeaders(path: path, headers: headers, liveToken: token(),
                                          dataRoot: dataRoot)
        // This entry is also callable without the listener's bearer gate.
        // Authenticate before identity resolution, parsing, or task creation.
        switch BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: token()) {
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
        // A revoked or wrong connection key stops working HERE, before any
        // route sees the request. The bearer opened the port; it does not
        // excuse a missing, revoked, or unknown contact credential.
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: dataRoot)
        if principal.peerID == nil {
            BridgeCore.writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        }
        if let peerID = principal.peerID { AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peerID, inbound: true) }

        let isGrok = principal.replyOnly
        // This credential may only answer a pending request, never call MCP,
        // A2A or general messaging. Identity comes from the verified bearer.
        if isGrok || path == "/agent/grok-reply" {
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
            Task {
                let endpoint = AgentContactA2AEndpoint(tasks: self.tasks(), port: port(),
                    grpcPort: grpcPort())
                let response = await endpoint.handleREST(method: method, target: path, body: body,
                    principal: principal, version: headers["a2a-version"])
                switch response {
                case .json(let status, let value, let onSent):
                    Self.writeA2AJSON(conn, status: status, object: value, onSent: { Task { await onSent?() } })
                case .stream(let events): AgentContactSSE.write(conn, id: "rest", events: events, version: "1.0", rest: true)
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
            // Her messages held for this host (it has no command line): a tool
            // call takes a bounded batch in one step, and its response settles
            // them: delivered once written, held again if it was not.
            let conversations = AgentConversationStore(dataRoot: dataRoot)
            let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let tool = request?["method"] as? String == "tools/call" ? (request?["params"] as? [String: Any])?["name"] as? String : nil
            let session = principal.conversationID(protocolName: "mcp") ?? ""
            let stamp = ISO8601DateFormatter()
            func wire(_ item: AgentConversationStore.Held) -> [String: String] {
                ["at": stamp.string(from: item.at), "text": item.text, "conversation_id": item.conversation ?? session]
            }
            let held: (taken: [AgentConversationStore.Held], remaining: Int) = tool.flatMap { _ in principal.peerID.flatMap { peer in
                try? conversations.takeHeld(agent: "peer:" + peer) { NativeAgentMCPWire.heldFits($0.map(wire)) }
            } } ?? ([], 0)
            let taken = held.taken
            let settle: @Sendable (Bool) -> Void = { written in
                guard !taken.isEmpty else { return }
                let name = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { $0.id == principal.peerID }?.name ?? "the host"
                do { try conversations.settleHeld(taken, written: written, to: name, via: tool ?? "MCP") }
                catch { nativeLog("AgentContactRoutes: held messages were not settled (they stay delivering until the next launch): %@", error.localizedDescription) }
            }
            switch NativeAgentMCPWire.parse(body, defaultSession: principal.conversationID(protocolName: "mcp"),
                                            held: (taken.map(wire), held.remaining)) {
            case .message(let message, let project):
                // SSE only to a relay that says it reads it: relays spawned before
                // this change advertise text/event-stream but accept only JSON.
                let wait = NativeAgentMCPWire.waitRequest(body)
                let mcpWait = (seconds: wait.seconds,
                               progressToken: headers["x-nativeagent-relay-sse"] == "1" ? wait.progressToken : nil)
                handleContactMessage(conn: conn, body: message, tasks: self.tasks(),
                              peer: peerTurnContext(principal: principal, protocolName: "mcp",
                                                    messageID: Self.mcpRequestID(message),
                                                    // The message, not the JSON-RPC envelope: a retry under
                                                    // the same request_id carries a new JSON-RPC id.
                                                    requestBody: message),
                              responseProjection: project, mcpWait: mcpWait, settle: settle)
            case .reply(let request, let session, let offset, let waitSeconds, let project):
                Task {
                    let tasks = self.tasks()
                    let receipt = await peerReplyReceipt(requestID: request, sessionID: session,
                        offset: offset, waitSeconds: waitSeconds, principal: principal, tasks: tasks)
                    let fetched = Self.fetched(receipt, principal: principal, tasks: tasks)
                    BridgeCore.writeJSON(conn, status: 200, obj: project(receipt), onSent: { fetched?(); settle(true) },
                                         onFailed: { settle(false) })
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
            Task {
                let response = await AgentContactA2AEndpoint(tasks: self.tasks(), port: port(),
                    grpcPort: grpcPort())
                    .handle(body, principal: principal, version: headers["a2a-version"])
                switch response {
                case .json(let object, let onSent):
                    BridgeCore.writeJSON(conn, status: 200, obj: object, onSent: { Task { await onSent?() } })
                case .stream(let id, let events, let version): AgentContactSSE.write(conn, id: id, events: events, version: version)
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
                BridgeCore.writeJSON(conn, status: result["status"] as? String == "invalid_request" ? 400 : 200, obj: result,
                          onSent: Self.fetched(result, principal: principal, tasks: tasks))
            }
        case "/agent/message":
            guard method == "POST" else {
                BridgeCore.writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleContactMessage(conn: conn, body: body, tasks: self.tasks(),
                          peer: peerTurnContext(principal: principal, protocolName: "agent-message",
                                                messageID: Self.mcpRequestID(body),
                                                requestBody: body))
        default:
            handled = false
        }
        }
        routeContact()
        return handled
    }

    typealias PeerTurnContext = ClaudeBridgeMessageRuntime.PeerTurnContext

    private func peerTurnContext(principal: AgentBridgePrincipal, protocolName: String, messageID: String?,
                                 requestBody: Data) -> PeerTurnContext {
        PeerTurnContext(
            principal: principal,
            protocolName: protocolName,
            messageID: messageID,
            // The ORIGINAL request bytes. A2A re-mints its server-side request
            // id on every send, so digesting the projected body would make two
            // identical client messages look different.
            bodyDigest: AgentPeerReplayClaimStore.digest(requestBody)
        )
    }

    /// The caller-supplied correlation id carried by the MCP `agent_message`
    /// body and the plain `/agent/message` body.
    static func mcpRequestID(_ body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return (json["request_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                  waitSeconds: Int = 0, principal: AgentBridgePrincipal, tasks: AgentContactTasks) async -> [String: Any] {
        let protocolSession = NativeAgentMCPWire.validSession(sessionID) || NativeAgentA2AWire.validContext(sessionID)
        let storedSession = protocolSession ? principal.storedConversation(sessionID) : sessionID
        guard storedSession.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)) else {
            return ["status": "invalid_request"]
        }
        let context = String(storedSession.dropFirst(AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id).count))
        let taskID = "na3.\(context).\(requestID)"
        // agent_reply's wait: back the moment the reply settles (its stream
        // ends with it), or when the caller's bound passes, as agent_message waits.
        // A wait that cannot watch the reply says why, never a silent immediate read.
        var waitIgnored: String?
        if waitSeconds > 0 {
            do {
                let events = try await tasks.subscribe(taskID, owner: principal.id)
                await Self.untilSettled(seconds: waitSeconds) {
                    for await event in events { if case .status(_, final: true) = event { return } }
                }
            } catch { waitIgnored = ((error as? AgentContactFailure)?.message ?? error.localizedDescription) + "; read as it is now." }
        }
        var receipt: [String: Any]
        if let task = try? await tasks.get(taskID, owner: principal.id) {
            receipt = Self.contactReply(task, requestID: requestID, sessionID: sessionID, offset: offset, maxChars: maxChars)
        } else {
            receipt = ClaudeBridgeMessageRuntime.agentReplyReceipt(requestID: requestID, sessionID: storedSession,
                offset: offset, maxChars: maxChars, logURL: ClaudeBridgeMessageRuntime.messageReplyURL())
            if receipt["session_id"] as? String == storedSession { receipt["session_id"] = sessionID }
        }
        if let waitIgnored { receipt["wait_ignored"] = waitIgnored }
        return receipt
    }

    private static func fetched(_ receipt: [String: Any], principal: AgentBridgePrincipal,
                                tasks: AgentContactTasks) -> (@Sendable () -> Void)? {
        guard receipt["status"] as? String == "ok", let reply = receipt["reply"] as? String, !reply.isEmpty,
              let session = receipt["session_id"] as? String, let request = receipt["request_id"] as? String,
              let run = receipt["run_id"] as? String, !run.isEmpty else { return nil }
        let stored = NativeAgentMCPWire.validSession(session) || NativeAgentA2AWire.validContext(session)
            ? principal.storedConversation(session) : session
        return { Task { await tasks.recordReplyFetch(session: stored, request: request, run: run) } }
    }

    /// The peer doors share A2A's retained execution; the legacy builder handler stays separate.
    private func handleContactMessage(conn: NWConnection, body: Data,
                                      tasks: AgentContactTasks, peer: PeerTurnContext,
                                      responseProjection: (@Sendable (Int, [String: Any]) -> [String: Any])? = nil,
                                      mcpWait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?)? = nil,
                                      settle: (@Sendable (Bool) -> Void)? = nil) {
        func reply(_ status: Int, _ object: [String: Any]) {
            BridgeCore.writeJSON(conn, status: responseProjection == nil ? status : 200,
                      obj: responseProjection?(status, object) ?? object,
                      onSent: { settle?(true) }, onFailed: { settle?(false) })
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              ClaudeBridgeMessageRuntime.validGenericAgentMessage(json), let text = json["text"] as? String else {
            reply(400, ["status": "rejected", "detail": "The message is invalid. Work: nothing ran."]); return
        }
        let principal = peer.principal
        let requested = json["sessionId"] as? String
        let protocolSession = peer.protocolName == "mcp"
        let stored = protocolSession ? requested.map(principal.storedConversation)
            : ClaudeBridgeMessageRuntime.genericAgentSessionID(requested: requested, owner: principal.id)
        guard let stored, stored.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)) else {
            reply(403, ["status": "rejected", "detail": "This conversation belongs to another contact. Work: nothing ran."]); return
        }
        let context = String(stored.dropFirst(AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id).count))
        let session = protocolSession ? context : stored
        let request = json["request_id"] as? String ?? UUID().uuidString
        let send = NativeAgentA2AWire.Send(rpcID: request, context: context, request: request,
            text: text, clientMessageID: request, parts: [.text(text)])
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

    /// Holds an MCP `agent_message` open until the reply settles or the
    /// caller's bound passes, so hosts get the answer without polling. With a
    /// progress token the answer is an SSE stream (Streamable HTTP): the reply
    /// so far as `notifications/progress`, then the tool result. Without one
    /// it is the same single JSON response, only later. The task, its receipt
    /// and replay claim are untouched: leaving early only ends this wait, and
    /// `agent_reply` still reads the same retained reply.
    private static func writeWaitedReply(conn: NWConnection, ack: [String: Any], taskID: String, requestID: String,
                                         sessionID: String, owner: String, tasks: AgentContactTasks,
                                         wait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?),
                                         project: @escaping @Sendable (Int, [String: Any]) -> [String: Any],
                                         settle: (@Sendable (Bool) -> Void)?) async {
        // Whatever ended the wait, held messages it carried that were not written stay held.
        defer { settle?(false) }
        guard let ackData = try? JSONSerialization.data(withJSONObject: ack) else { conn.cancel(); return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await writeWaitedReplyBody(conn: conn, ackData: ackData, taskID: taskID, requestID: requestID,
                    sessionID: sessionID, owner: owner, tasks: tasks, wait: wait, project: project, settle: settle)
            }
            group.addTask {
                // Bound all writes, with one second to send the result after the wait expires.
                try? await Task.sleep(for: .seconds(wait.seconds + 1))
            }
            await group.next()
            group.cancelAll()
        }
        conn.cancel()
    }

    private static func writeWaitedReplyBody(conn: NWConnection, ackData: Data, taskID: String, requestID: String,
                                             sessionID: String, owner: String, tasks: AgentContactTasks,
                                             wait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?),
                                             project: @escaping @Sendable (Int, [String: Any]) -> [String: Any],
                                             settle: (@Sendable (Bool) -> Void)?) async {
        guard let ack = try? JSONSerialization.jsonObject(with: ackData) as? [String: Any] else { return }
        @Sendable func send(_ data: Data) async -> Bool {
            let write = ContactStreamWrite()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { done in
                    guard write.start(done) else { return }
                    conn.send(content: data, completion: .contentProcessed { write.finish($0 == nil) })
                }
            } onCancel: {
                write.finish(false)
                conn.cancel()
            }
        }
        @Sendable func frame(_ object: [String: Any]) -> Data {
            var data = Data("event: message\ndata: ".utf8)
            data.append((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
            data.append(Data("\n\n".utf8))
            return data
        }
        let token = wait.progressToken
        if token != nil, await !send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)) {
            conn.cancel(); return
        }
        if let events = try? await tasks.subscribe(taskID, owner: owner) {
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
                    guard await send(frame(NativeAgentMCPWire.progress(token, step: step, message: message))) else { return }
                }
            }
        }
        var receipt = ack
        var fetchedTask: AgentContactTask?
        if let task = try? await tasks.get(taskID, owner: owner) {
            receipt.merge(contactReply(task, requestID: requestID, sessionID: sessionID, offset: 0, maxChars: 8000)) { ack, _ in ack }
            if let reply = receipt["reply"] as? String, !reply.isEmpty { fetchedTask = task }
        }
        let response = project(200, receipt)
        let sent: Bool
        if token != nil {
            sent = await send(frame(response))
        } else {
            guard let body = try? JSONSerialization.data(withJSONObject: response) else { return }
            var data = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            data.append(body)
            sent = await send(data)
        }
        settle?(sent)
        if sent, let fetchedTask { await tasks.recordReplyFetch(fetchedTask) }
    }

    /// The caller's wait on a reply (agent_message's, agent_reply's): `watch`
    /// returns when the reply settles, or the caller's bound passes first.
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
        let reply = task.state == .failed ? (task.detail ?? "The reply could not be completed. Work: outcome unknown.") : task.text
        guard offset >= 0, offset <= reply.count, (1...16000).contains(maxChars) else { return ["status": "invalid_request"] }
        let slice = String(reply.dropFirst(offset).prefix(maxChars))
        var receipt: [String: Any] = ["status": task.state.terminal ? "ok" : "pending",
            "original_status": task.state.rawValue, "request_id": requestID, "session_id": sessionID,
            "run_id": task.canonicalRunID ?? "", "reply": slice, "offset": offset,
            "next_offset": offset + slice.count, "has_more": offset + slice.count < reply.count]
        if let detail = task.detail { receipt["detail"] = detail }
        if let result = task.toolResult { receipt["result"] = AgentContactPart.object(result) }
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

private final class ContactStreamWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func start(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

extension AgentContactRoutes {
    static func writeA2AJSON(_ connection: NWConnection, status: Int, object: [String: Any], onSent: (@Sendable () -> Void)? = nil) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { connection.cancel(); return }
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 500 ? "Internal Server Error" : "Bad Request"))
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/a2a+json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { error in
            if error == nil { onSent?() }
            connection.cancel()
        })
    }
}
