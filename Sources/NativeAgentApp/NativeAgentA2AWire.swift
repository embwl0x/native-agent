import Foundation
import CoreFoundation
import PersonaEngine
import PersistenceCore
import ChatOrchestration
import NativeAgentCore

/// The name peers see for this agent: the persona's own name, or "the agent"
/// when no persona name is set.
enum PeerFacingIdentity {
    static var agentName: String {
        let name = PersonaCompiler.agentDisplayName()
        return name == "NativeAgent" ? "the agent" : name
    }
}

/// A bounded A2A 1.0/0.3 JSON-RPC projection over the bridge's existing turn/receipt owners.
/// No protocol-specific session store, task runner, listener, or authority is created.
enum NativeAgentA2AWire {
    // rpcID is restricted by parse to immutable String/NSNumber values.
    struct Send: @unchecked Sendable {
        let rpcID: Any
        let context: String
        let request: String
        let text: String
        /// The CALLER's own `messageId`, kept rather than discarded: `request`
        /// below is a freshly minted server UUID and so is unique on every
        /// resend, which makes it useless as a replay identity. This is the id
        /// `AgentPeerReplayClaimStore` claims.
        let clientMessageID: String
        var parts: [AgentContactPart] = []
        var streaming = false
        var blocking = false
        var continuedTask: String?
        var acceptedOutputModes = ["*/*"]
        var pushConfig: JSONValue?
        var taskID: String { "na3.\(context).\(request)" }
        var body: Data { try! JSONSerialization.data(withJSONObject: ["text": text, "sessionId": context, "request_id": request]) }
    }
    enum Action: @unchecked Sendable {
        case send(Send)
        case get(id: Any, task: String, context: String, request: String)
        case subscribe(id: Any, task: String)
        case cancel(id: Any, task: String)
        case list(id: Any, params: [String: Any])
        case push(id: Any, operation: String, params: [String: Any])
        case extended(id: Any)
        case response([String: Any])
    }

    static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    static func result(_ id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }
    static func validContext(_ value: String) -> Bool {
        value.hasPrefix("a2a-") && value.count == 40 && UUID(uuidString: String(value.dropFirst(4))) != nil
    }
    static func locator(_ value: String) -> (context: String, request: String)? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "na3", let request = parts.last,
              request.count == 36, UUID(uuidString: String(request)) != nil else { return nil }
        let context = parts.dropFirst().dropLast().joined(separator: ".")
        guard context.utf8.count <= 128,
              NativeAgentChatSessionID.normalizedPathComponent(context) == context else { return nil }
        return (context, String(request))
    }
    static func parse(_ body: Data, defaultContext: String? = nil) -> Action {
        guard body.count <= 4 * 1024 * 1024 else {
            return .response(error(NSNull(), -32600, "Message is too large"))
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return .response(error(NSNull(), -32700, "Invalid JSON"))
        }
        guard let json = decoded as? [String: Any] else {
            return .response(error(NSNull(), -32600, "One request is required"))
        }
        let id = json["id"] ?? NSNull()
        let numericID = (id as? NSNumber).map {
            CFGetTypeID($0) != CFBooleanGetTypeID() && $0.stringValue == String($0.int64Value)
        } ?? false
        let stringID = (id as? String).map { $0.utf8.count <= 256 } ?? false
        guard json["jsonrpc"] as? String == "2.0", stringID || numericID,
              let method = json["method"] as? String else {
            return .response(error(NSNull(), -32600, "A single JSON-RPC request with an ID is required"))
        }
        let methods: Set<String> = ["message/send", "SendMessage", "message/stream", "SendStreamingMessage", "tasks/get", "GetTask",
            "tasks/cancel", "CancelTask", "tasks/resubscribe", "SubscribeToTask", "ListTasks", "GetExtendedAgentCard", "agent/getAuthenticatedExtendedCard",
            "CreateTaskPushNotificationConfig", "GetTaskPushNotificationConfig", "ListTaskPushNotificationConfigs", "DeleteTaskPushNotificationConfig",
            "tasks/pushNotificationConfig/set", "tasks/pushNotificationConfig/get", "tasks/pushNotificationConfig/list", "tasks/pushNotificationConfig/delete"]
        guard methods.contains(method) else { return .response(error(id, -32601, "Method not supported")) }
        guard let params = (json["params"] ?? [String: Any]()) as? [String: Any] else {
            return .response(error(id, -32602, "Object params required"))
        }
        let modern = !method.contains("/")
        if let tenant = params["tenant"], (tenant as? String) != "" {
            return .response(error(id, -32602, "This interface has no tenant"))
        }
        if let config = params["configuration"] as? [String: Any],
           let length = config["historyLength"], !validHistoryLength(length) {
            return .response(error(id, -32602, "historyLength must be a nonnegative integer"))
        }
        switch method {
        case "message/send", "SendMessage", "message/stream", "SendStreamingMessage":
            guard let message = params["message"] as? [String: Any],
                  (modern || message["kind"] as? String == "message"), message["role"] as? String == (modern ? "ROLE_USER" : "user"),
                  let messageID = message["messageId"] as? String, !messageID.isEmpty, messageID.utf8.count <= 128,
                  let parts = message["parts"] as? [[String: Any]], !parts.isEmpty, parts.count <= 32 else {
                return .response(error(id, -32602, "A user message with an ID and 1–32 parts is required"))
            }
            let decodedParts: [AgentContactPart]
            do { decodedParts = try parts.map { try AgentContactPart.decode($0, version: modern ? "1.0" : "0.3") } }
            catch let failure as AgentContactFailure { return .response(error(id, failure.code, failure.message)) }
            catch { return .response(Self.error(id, -32602, "Invalid message parts")) }
            var blocking = modern
            var acceptedOutputModes = ["*/*"]
            if let task = message["taskId"] {
                guard let task = task as? String, locator(task) != nil else {
                    return .response(error(id, -32001, "Task not found"))
                }
            }
            if let config = params["configuration"] {
                guard let config = config as? [String: Any] else { return .response(error(id, -32602, "Invalid options")) }
                if !modern, config["pushNotificationConfig"] != nil { return .response(error(id, -32003, "Push notifications require A2A 1.0")) }
                if let raw = config[modern ? "returnImmediately" : "blocking"] {
                    guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                        return .response(error(id, -32602, "blocking must be true or false"))
                    }
                    blocking = modern ? !value.boolValue : value.boolValue
                }
                if let modes = config["acceptedOutputModes"] {
                    guard let modes = modes as? [String], !modes.isEmpty else { return .response(error(id, -32602, "Invalid output types")) }
                    guard modes.contains("text/plain") || modes.contains("*/*") else {
                        return .response(error(id, -32005, "Replies require text/plain support"))
                    }
                    acceptedOutputModes = modes
                }
            }
            let context: String
            if let raw = message["contextId"] {
                guard let supplied = raw as? String, validContext(supplied) else {
                    return .response(error(id, -32602, "Continue only a server-issued A2A contextId"))
                }
                context = supplied
            } else if let task = message["taskId"] as? String, let existing = locator(task) {
                context = existing.context
            } else { context = defaultContext ?? "a2a-" + UUID().uuidString.lowercased() }
            if let task = message["taskId"] as? String, locator(task)?.context != context {
                return .response(error(id, -32602, "Task and conversation do not match"))
            }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard text.utf8.count <= 64000,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || decodedParts.contains(where: { $0.isAttachment }) else {
                return .response(error(id, -32602, "Provide text or an attachment; text is limited to 64000 bytes"))
            }
            var send = Send(rpcID: id, context: context, request: UUID().uuidString.lowercased(), text: text, clientMessageID: messageID)
            send.parts = decodedParts
            send.streaming = method == "message/stream" || method == "SendStreamingMessage"
            send.blocking = blocking
            send.continuedTask = message["taskId"] as? String
            send.acceptedOutputModes = acceptedOutputModes
            if let config = params["configuration"] as? [String: Any], let push = config["taskPushNotificationConfig"] {
                guard modern, push is [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: push),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
                    return .response(error(id, -32602, "Invalid taskPushNotificationConfig"))
                }
                send.pushConfig = value
            }
            return .send(send)
        case "tasks/get", "GetTask", "tasks/cancel", "CancelTask", "tasks/resubscribe", "SubscribeToTask":
            guard params["id"] is String else { return .response(error(id, -32602, "A task ID is required")) }
            guard let task = params["id"] as? String, let value = locator(task) else {
                return .response(error(id, -32001, "Task not found; use the exact returned task ID"))
            }
            if let length = params["historyLength"] {
                guard validHistoryLength(length) else {
                    return .response(error(id, -32602, "historyLength must be a nonnegative integer"))
                }
            }
            if method == "tasks/cancel" || method == "CancelTask" { return .cancel(id: id, task: task) }
            if method == "tasks/resubscribe" || method == "SubscribeToTask" { return .subscribe(id: id, task: task) }
            return .get(id: id, task: task, context: value.context, request: value.request)
        case "ListTasks": return .list(id: id, params: params)
        case "CreateTaskPushNotificationConfig", "GetTaskPushNotificationConfig", "ListTaskPushNotificationConfigs", "DeleteTaskPushNotificationConfig":
            return .push(id: id, operation: method, params: params)
        case "tasks/pushNotificationConfig/set", "tasks/pushNotificationConfig/get", "tasks/pushNotificationConfig/list", "tasks/pushNotificationConfig/delete":
            return .response(error(id, -32003, "Push notifications are not available"))
        case "agent/getAuthenticatedExtendedCard", "GetExtendedAgentCard":
            return .extended(id: id)
        default:
            return .response(error(id, -32601, "Method not supported"))
        }
    }
    static func validHistoryLength(_ value: Any) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.doubleValue >= 0 && n.doubleValue <= Double(Int32.max) && n.doubleValue.rounded() == n.doubleValue
    }
    static func acknowledgement(_ send: Send, status: Int, body: [String: Any]) -> [String: Any] {
        guard status == 200, body["ack"] as? String == "enqueued",
              let request = body["requestId"] as? String, UUID(uuidString: request) != nil,
              let context = body["sessionId"] as? String, validContext(context) else {
            return error(send.rpcID, -32603, "Enqueue not confirmed; outcome unknown. Do not automatically resend. Task ID: \(send.taskID)")
        }
        return result(send.rpcID, ["kind": "task", "id": "na3.\(context).\(request)", "contextId": context,
                                  "status": ["state": "submitted"],
                                  "metadata": ["receiptRetention": "Best effort; absent receipts do not prove failure or authorize replay"]])
    }
    static func receipt(id: Any, task: String, context: String, request: String, body: [String: Any]) -> [String: Any] {
        guard body["status"] as? String == "ok", body["request_id"] as? String == request,
              body["session_id"] as? String == context else {
            return error(id, -32001, "No exact retained task receipt is available. The task may still be running, or evidence may be unavailable. Do not resend based on absence.")
        }
        guard body["has_more"] as? Bool != true else {
            return error(id, -32603, "Reply exceeds this endpoint's 16000-character output limit; recover through /agent/reply using the task's request and context IDs")
        }
        let original = body["original_status"] as? String ?? "unknown"
        let state: String
        switch original {
        case "ok": state = "completed"
        case "chat_failed", "no_reply": state = "failed"
        default: return error(id, -32603, "Retained receipt has an unrecognized terminal state")
        }
        var taskBody: [String: Any] = ["kind": "task", "id": task, "contextId": context, "status": ["state": state]]
        if original == "no_reply" {
            taskBody["status"] = ["state": state, "message": ["kind": "message", "role": "agent",
                "messageId": request + "-no-reply", "contextId": context, "taskId": task,
                "parts": [["kind": "text", "text": "The turn ended without an answer. Work may have occurred; this does not authorize automatic replay."]]]]
        }
        if let reply = body["reply"] as? String, !reply.isEmpty {
            taskBody["artifacts"] = [["artifactId": request, "parts": [["kind": "text", "text": reply]]]]
        }
        return result(id, taskBody)
    }
    static func card(port: UInt16, version: String = "1.0", agentName: String? = nil, extended: Bool = false,
                     grpcPort: UInt16? = nil) -> [String: Any] {
        let agent = agentName ?? PeerFacingIdentity.agentName
        var card: [String: Any] = ["protocolVersion": "0.3.0", "name": agent, "version": "1.0.0",
         "description": "Talk, share files and receive replies as they are written. Reconnect to ongoing work or cancel it. Permission cards stay with the person. Files use embedded bytes; links are not fetched. Access is local and requires a key. Tasks are retained for this app run, up to 128 tasks. Push notifications are not available.",
         "url": "http://127.0.0.1:\(port)/a2a", "preferredTransport": "JSONRPC",
         "capabilities": ["streaming": true, "pushNotifications": false],
         "defaultInputModes": AgentContactPart.inputModes, "defaultOutputModes": ["text/plain", "application/json", "application/octet-stream"],
         "securitySchemes": ["bridgeBearer": ["type": "http", "scheme": "bearer"]],
         "security": [["bridgeBearer": [String]()]],
         "skills": [["id": "conversation", "name": "Talk with \(agent)", "description": "Full persona, memory retrieval, Fluid Context and persistent conversation history with ordinary tool permission gates", "tags": ["conversation"]]]]
        if version == "1.0" {
            card.removeValue(forKey: "protocolVersion")
            card.removeValue(forKey: "url")
            card.removeValue(forKey: "preferredTransport")
            card.removeValue(forKey: "security")
            card["supportedInterfaces"] = [
                ["url": "http://127.0.0.1:\(port)/a2a", "protocolVersion": "1.0", "protocolBinding": "JSONRPC"],
                ["url": "http://127.0.0.1:\(port)/a2a", "protocolVersion": "1.0", "protocolBinding": "HTTP+JSON"],
                ["url": "http://127.0.0.1:\(port)/a2a", "protocolVersion": "0.3", "protocolBinding": "JSONRPC"]]
            if let grpcPort, grpcPort != 0 {
                var interfaces = card["supportedInterfaces"] as! [[String: String]]
                interfaces.insert(["url": "http://127.0.0.1:\(grpcPort)", "protocolVersion": "1.0", "protocolBinding": "GRPC"], at: 2)
                card["supportedInterfaces"] = interfaces
            }
            card["capabilities"] = ["streaming": true, "pushNotifications": true, "extendedAgentCard": true]
            card["description"] = "Talk, share embedded files, stream replies, list retained tasks or cancel work. Authenticated local access; outbound push supports validated webhooks. This listener stays loopback-only; remote peers use polling or streaming."
            card["securitySchemes"] = ["bridgeBearer": ["httpAuthSecurityScheme": ["scheme": "bearer"]]]
            card["securityRequirements"] = [["schemes": ["bridgeBearer": ["list": [String]()]]]]
        }
        if version == "0.3" { card["supportsAuthenticatedExtendedCard"] = true }
        if extended {
            card["skills"] = [["id": "conversation", "name": "Talk with \(agent)",
                "description": "Persistent peer conversations with persona, memory retrieval and ordinary tool permissions. Permission cards stay with the person. Embedded files only; file links are not fetched. Task listing covers this app run's bounded 128-task index; history is not exported.", "tags": ["conversation", "files", "tasks"]]]
        }
        return card
    }
}
