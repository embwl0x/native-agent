import Foundation
import CoreFoundation

/// A bounded A2A 0.3 JSON-RPC projection over the bridge's existing turn/receipt owners.
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
        var taskID: String { "na3.\(context).\(request)" }
        var body: Data { try! JSONSerialization.data(withJSONObject: ["text": text, "sessionId": context, "request_id": request]) }
    }
    enum Action {
        case send(Send)
        case get(id: Any, task: String, context: String, request: String)
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
        guard parts.count == 3, parts[0] == "na3", validContext(String(parts[1])),
              parts[2].count == 36, UUID(uuidString: String(parts[2])) != nil else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
    static func parse(_ body: Data) -> Action {
        guard body.count <= 70000,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .response(error(NSNull(), -32700, "Invalid or oversized JSON request"))
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
        guard let params = json["params"] as? [String: Any] else {
            return .response(error(id, -32602, "Object params required"))
        }
        switch method {
        case "message/send":
            guard let message = params["message"] as? [String: Any],
                  message["kind"] as? String == "message", message["role"] as? String == "user",
                  let messageID = message["messageId"] as? String, !messageID.isEmpty, messageID.utf8.count <= 128,
                  let parts = message["parts"] as? [[String: Any]], !parts.isEmpty, parts.count <= 32 else {
                return .response(error(id, -32602, "A bounded user message with messageId and text parts is required"))
            }
            guard message["taskId"] == nil else {
                return .response(error(id, -32004, "Task resumption is unsupported; continue the contextId as a new task"))
            }
            guard parts.allSatisfy({ $0["kind"] as? String == "text" && $0["text"] is String }) else {
                return .response(error(id, -32005, "Only text parts are supported"))
            }
            if let config = params["configuration"] {
                // The tagged 0.3 JSON schema declares blocking optional with
                // no default. Only explicit true requests waiting; this bounded
                // endpoint rejects it before enqueue rather than silently ignoring it.
                guard let config = config as? [String: Any], config["pushNotificationConfig"] == nil,
                      config["blocking"] == nil || config["blocking"] as? Bool == false,
                      config["acceptedOutputModes"] == nil || (config["acceptedOutputModes"] as? [String])?.contains("text/plain") == true else {
                    return .response(error(id, -32004, "Use nonblocking text/plain delivery; push notifications are unsupported"))
                }
            }
            let context: String
            if let raw = message["contextId"] {
                guard let supplied = raw as? String, validContext(supplied) else {
                    return .response(error(id, -32602, "Continue only a server-issued A2A contextId"))
                }
                context = supplied
            } else { context = "a2a-" + UUID().uuidString.lowercased() }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64000 else {
                return .response(error(id, -32602, "Text must contain 1–64000 UTF-8 bytes"))
            }
            return .send(Send(rpcID: id, context: context, request: UUID().uuidString.lowercased(),
                              text: text, clientMessageID: messageID))
        case "tasks/get":
            guard let task = params["id"] as? String, let value = locator(task) else {
                return .response(error(id, -32001, "Task not found; use the exact returned task ID"))
            }
            return .get(id: id, task: task, context: value.context, request: value.request)
        case "tasks/cancel":
            return .response(error(id, -32002, "Task cancellation is unsupported by this endpoint"))
        default:
            return .response(error(id, -32601, "Method not supported"))
        }
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
    static func card(port: UInt16) -> [String: Any] {
        ["protocolVersion": "0.3.0", "name": "Agent", "version": "1.0.0",
         "description": "Persistent full NativeAgent conversations. Text only, nonblocking send/get; replies up to 16000 characters. Continue contextId with a new task. No task resumption, streaming, push, or cancellation. Local authenticated access only.",
         "url": "http://127.0.0.1:\(port)/a2a", "preferredTransport": "JSONRPC",
         "capabilities": ["streaming": false, "pushNotifications": false],
         "defaultInputModes": ["text/plain"], "defaultOutputModes": ["text/plain"],
         "securitySchemes": ["bridgeBearer": ["type": "http", "scheme": "bearer"]],
         "security": [["bridgeBearer": [String]()]],
         "skills": [["id": "conversation", "name": "Talk with Agent", "description": "Full persona, memory retrieval, Fluid Context and persistent conversation history with ordinary tool permission gates", "tags": ["conversation"]]]]
    }
}
