import GrokLink
import Foundation
import CoreFoundation
import Network
import Agents
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

extension ClaudeBridge {
    static let contactPaths: Set<String> = ["/agent/grok-reply", "/agent/mcp", "/.well-known/agent-card.json", "/a2a", "/agent/card", "/agent/reply", "/agent/message"]
    static func isContactPath(_ path: String) -> Bool {
        contactPaths.contains(path) || path.hasPrefix("/a2a/")
    }

    /// Adapt a verified contact credential to the existing listener gate. This
    /// is internal only and is never applied to builder or control routes.
    static func contactHeaders(path: String, headers: [String: String], liveToken: String,
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

    func received(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        route(conn: conn, method: method, path: path,
              headers: Self.contactHeaders(path: path, headers: headers, liveToken: token,
                                           dataRoot: NativeAgentPaths.dataRoot), body: body)
    }

    func routeAgentContact(conn: NWConnection, method: String, path: String,
                           headers: [String: String], body: Data,
                           dataRoot: URL = NativeAgentPaths.dataRoot,
                           liveToken: String? = nil,
                           readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) },
                           tasks: AgentContactTasks? = nil,
                           advertisedPort: UInt16? = nil,
                           advertisedGRPCPort: UInt16? = nil) -> Bool {
        guard Self.isContactPath(path) else {
            return false
        }
        let headers = Self.contactHeaders(path: path, headers: headers, liveToken: liveToken ?? token,
                                          dataRoot: dataRoot, readCredential: readCredential)
        // This entry is also callable without the listener's bearer gate.
        // Authenticate before identity resolution, parsing, or task creation.
        switch BridgeCore.authorize(authorizationHeader: headers["authorization"], liveToken: liveToken ?? token) {
        case .serverStopping:
            writeJSON(conn, status: 503, obj: ["error": "server_stopping"])
            return true
        case .unauthorized:
            writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return true
        case .authorized:
            break
        }
        var handled = true
        func routeContact() {
        // A revoked or wrong connection key stops working HERE, before any
        // route sees the request. The bearer opened the port; it does not
        // excuse a missing, revoked, or unknown contact credential.
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: dataRoot, readCredential: readCredential)
        if principal.peerID == nil {
            writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        }

        let isGrok = principal.replyOnly
        // This credential may only answer a pending request, never call MCP,
        // A2A or general messaging. Identity comes from the verified bearer.
        if isGrok || path == "/agent/grok-reply" {
            guard isGrok, path == "/agent/grok-reply", method == "POST", body.count <= GrokReplyInput.maximumBytes else {
                writeJSON(conn, status: 403, obj: ["error": "reply_scope_only"])
                return
            }
            Task {
                do {
                    try await NativeAgentEngine.live.agents.grok.receive(GrokReplyInput.parse(body), principal: principal, dataRoot: dataRoot)
                    writeJSON(conn, status: 200, obj: ["status": "answered"])
                } catch {
                    writeJSON(conn, status: 409, obj: ["error": "unknown_expired_or_already_answered_message"])
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
                let endpoint = AgentContactA2AEndpoint(tasks: tasks ?? NativeAgentEngine.live.agents.tasks, port: advertisedPort ?? activePort,
                    grpcPort: advertisedGRPCPort ?? NativeAgentA2AGRPCListener.shared.port)
                let response = await endpoint.handleREST(method: method, target: path, body: body,
                    principal: principal, version: headers["a2a-version"])
                switch response {
                case .json(let status, let value): Self.writeA2AJSON(conn, status: status, object: value)
                case .stream(let events): AgentContactSSE.write(conn, id: "rest", events: events, version: "1.0", rest: true)
                }
            }
            return
        }

        switch path {
        case "/agent/mcp":
            if let origin = headers["origin"], origin != "http://127.0.0.1:\(activePort)" {
                writeJSON(conn, status: 403, obj: ["error": "unsupported_mcp_origin"])
                return
            }
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            if let rejection = Self.mcpTransportRejection(headers: headers, port: activePort) {
                writeJSON(conn, status: rejection, obj: ["error": "unsupported_mcp_transport_headers"])
                return
            }
            switch NativeAgentMCPWire.parse(body, defaultSession: principal.conversationID(protocolName: "mcp")) {
            case .message(let message, let project):
                // SSE only to a relay that says it reads it: relays spawned before
                // this change advertise text/event-stream but accept only JSON.
                let wait = NativeAgentMCPWire.waitRequest(body)
                let mcpWait = (seconds: wait.seconds,
                               progressToken: headers["x-nativeagent-relay-sse"] == "1" ? wait.progressToken : nil)
                handleContactMessage(conn: conn, body: message, tasks: tasks ?? NativeAgentEngine.live.agents.tasks,
                              peer: peerTurnContext(principal: principal, protocolName: "mcp",
                                                    messageID: Self.mcpRequestID(message),
                                                    // The message, not the JSON-RPC envelope: a retry under
                                                    // the same request_id carries a new JSON-RPC id.
                                                    requestBody: message),
                              responseProjection: project, mcpWait: mcpWait)
            case .reply(let request, let session, let offset, let project):
                Task {
                    writeJSON(conn, status: 200, obj: project(await peerReplyReceipt(requestID: request, sessionID: session,
                        offset: offset, principal: principal, tasks: tasks ?? NativeAgentEngine.live.agents.tasks)))
                }
            case .immediate(let status, let response): writeJSON(conn, status: status, obj: response)
            case .acceptedNotification:
                conn.send(content: Data("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        case "/.well-known/agent-card.json":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            let cardVersion = headers["a2a-version"]?.hasPrefix("0.3") == true ? "0.3" : "1.0"
            writeJSON(conn, status: 200, obj: NativeAgentA2AWire.card(port: advertisedPort ?? activePort, version: cardVersion,
                grpcPort: advertisedGRPCPort ?? NativeAgentA2AGRPCListener.shared.port))
        case "/a2a":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            Task {
                let response = await AgentContactA2AEndpoint(tasks: tasks ?? NativeAgentEngine.live.agents.tasks, port: advertisedPort ?? activePort,
                    grpcPort: advertisedGRPCPort ?? NativeAgentA2AGRPCListener.shared.port)
                    .handle(body, principal: principal, version: headers["a2a-version"])
                switch response {
                case .json(let object): writeJSON(conn, status: 200, obj: object)
                case .stream(let id, let events, let version): AgentContactSSE.write(conn, id: id, events: events, version: version)
                }
            }
        case "/agent/card":
            guard method == "GET" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            writeJSON(conn, status: 200, obj: Self.agentPeerCard())
        case "/agent/reply":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let requestID = json["request_id"] as? String,
                  let sessionID = json["session_id"] as? String else {
                writeJSON(conn, status: 400, obj: ["error": "request_id_and_session_id_required"])
                return
            }
            guard (json["offset"] == nil || Self.peerInteger(json["offset"]) != nil),
                  (json["max_chars"] == nil || Self.peerInteger(json["max_chars"]) != nil) else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_pagination"])
                return
            }
            Task {
                let result = await peerReplyReceipt(requestID: requestID, sessionID: sessionID,
                    offset: Self.peerInteger(json["offset"]) ?? 0, maxChars: Self.peerInteger(json["max_chars"]) ?? 8000,
                    principal: principal, tasks: tasks ?? NativeAgentEngine.live.agents.tasks)
                writeJSON(conn, status: result["status"] as? String == "invalid_request" ? 400 : 200, obj: result)
            }
        case "/agent/message":
            guard method == "POST" else {
                writeJSON(conn, status: 405, obj: ["error": "method_not_allowed"])
                return
            }
            handleContactMessage(conn: conn, body: body, tasks: tasks ?? NativeAgentEngine.live.agents.tasks,
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

    private func peerReplyReceipt(requestID: String, sessionID: String, offset: Int = 0,
                                  maxChars: Int = 8000, principal: AgentBridgePrincipal, tasks: AgentContactTasks) async -> [String: Any] {
        let protocolSession = NativeAgentMCPWire.validSession(sessionID) || NativeAgentA2AWire.validContext(sessionID)
        let storedSession = protocolSession ? principal.storedConversation(sessionID) : sessionID
        guard storedSession.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id)) else {
            return ["status": "invalid_request"]
        }
        let context = String(storedSession.dropFirst(AgentBridgePrincipal.genericAgentSessionPrefix(owner: principal.id).count))
        if let task = try? await tasks.get("na3.\(context).\(requestID)", owner: principal.id) {
            return Self.contactReply(task, requestID: requestID, sessionID: sessionID, offset: offset, maxChars: maxChars)
        }
        var receipt = ClaudeBridgeMessageRuntime.agentReplyReceipt(requestID: requestID, sessionID: storedSession,
            offset: offset, maxChars: maxChars, logURL: ClaudeBridgeMessageRuntime.messageReplyURL())
        if receipt["session_id"] as? String == storedSession { receipt["session_id"] = sessionID }
        return receipt
    }

    /// The peer doors share A2A's retained execution; the legacy builder handler stays separate.
    private func handleContactMessage(conn: NWConnection, body: Data,
                                      tasks: AgentContactTasks, peer: PeerTurnContext,
                                      responseProjection: (@Sendable (Int, [String: Any]) -> [String: Any])? = nil,
                                      mcpWait: (seconds: Int, progressToken: NativeAgentMCPWire.ID?)? = nil) {
        func reply(_ status: Int, _ object: [String: Any]) {
            writeJSON(conn, status: responseProjection == nil ? status : 200,
                      obj: responseProjection?(status, object) ?? object)
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
                    owner: principal.id, tasks: tasks, wait: mcpWait, project: responseProjection)
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
                                         project: @escaping @Sendable (Int, [String: Any]) -> [String: Any]) async {
        @Sendable func send(_ data: Data) async -> Bool {
            await withCheckedContinuation { done in
                conn.send(content: data, completion: .contentProcessed { done.resume(returning: $0 == nil) })
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
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var step = 0, last = Date.distantPast
                    for await event in events {
                        let task: AgentContactTask
                        switch event {
                        case .status(let current, let final):
                            if final { return }
                            task = current
                        case .snapshot(let current), .artifact(let current, _, _, _): task = current
                        }
                        guard let token, Date().timeIntervalSince(last) >= 0.5 else { continue }
                        let message = task.state == .inputRequired ? (task.detail ?? "Waiting for the person")
                            : task.text.isEmpty ? "\(agent) is working" : String(task.text.suffix(2000))
                        last = Date(); step += 1
                        guard await send(frame(NativeAgentMCPWire.progress(token, step: step, message: message))) else { return }
                    }
                }
                group.addTask { try? await Task.sleep(for: .seconds(wait.seconds)) }
                await group.next()
                group.cancelAll()
            }
        }
        var receipt = ack
        if let task = try? await tasks.get(taskID, owner: owner) {
            receipt.merge(contactReply(task, requestID: requestID, sessionID: sessionID, offset: 0, maxChars: 8000)) { ack, _ in ack }
        }
        let response = project(200, receipt)
        guard token != nil else { BridgeCore.writeJSON(conn, status: 200, obj: response); return }
        _ = await send(frame(response))
        conn.cancel()
    }

    static func contactReply(_ task: AgentContactTask, requestID: String, sessionID: String,
                             offset: Int, maxChars: Int) -> [String: Any] {
        let reply = task.state == .failed ? (task.detail ?? "The reply could not be completed. Work: outcome unknown.") : task.text
        guard offset >= 0, offset <= reply.count, (1...16000).contains(maxChars) else { return ["status": "invalid_request"] }
        let slice = String(reply.dropFirst(offset).prefix(maxChars))
        var receipt: [String: Any] = ["status": task.state.terminal ? "ok" : "pending",
            "original_status": task.state.rawValue, "request_id": requestID, "session_id": sessionID,
            "run_id": task.canonicalRunID ?? "", "reply": slice, "offset": offset,
            "next_offset": offset + slice.count, "has_more": offset + slice.count < reply.count]
        if let detail = task.detail { receipt["detail"] = detail }
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

extension ClaudeBridge {
    static func writeA2AJSON(_ connection: NWConnection, status: Int, object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { connection.cancel(); return }
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 500 ? "Internal Server Error" : "Bad Request"))
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/a2a+json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
