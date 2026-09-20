import Foundation
import Network

extension AgentContactA2AEndpoint {
    enum RESTResponse: @unchecked Sendable {
        case json(Int, [String: Any])
        case stream(AsyncStream<AgentContactEvent>)
    }

    /// REST is a binding over the same parser, task owner and projections.
    /// This entry is reached only after the contact route's bearer check.
    func handleREST(method: String, target: String, body: Data,
                    principal: AgentBridgePrincipal, version: String?) async -> RESTResponse {
        do {
            guard let url = URLComponents(string: target), url.fragment == nil,
                  url.path.hasPrefix("/a2a/") else {
                return Self.restError(code: -32602, message: "Invalid request target")
            }
            let path = String(url.path.dropFirst(4))
            var params: [String: Any] = [:]
            for item in url.queryItems ?? [] {
                guard params[item.name] == nil, let value = item.value else {
                    return Self.restError(code: -32602, message: "Invalid or repeated query parameter")
                }
                switch item.name {
                case "pageSize", "historyLength":
                    guard !value.isEmpty, value.allSatisfy(\.isNumber), let number = Int(value) else {
                        return Self.restError(code: -32602, message: "Invalid integer query parameter")
                    }
                    params[item.name] = number
                case "includeArtifacts":
                    guard ["true", "false"].contains(value) else {
                        return Self.restError(code: -32602, message: "Invalid boolean query parameter")
                    }
                    params[item.name] = value == "true"
                default: params[item.name] = value
                }
            }
            if !body.isEmpty {
                guard method == "POST", let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return Self.restError(code: -32602, message: "Object body required")
                }
                for (key, value) in object {
                    guard params[key] == nil else { return Self.restError(code: -32602, message: "Repeated request parameter") }
                    params[key] = value
                }
            }
            let operation: String
            switch (method, path) {
            case ("POST", "/message:send"): operation = "SendMessage"
            case ("POST", "/message:stream"): operation = "SendStreamingMessage"
            case ("GET", "/tasks"): operation = "ListTasks"
            case ("GET", "/extendedAgentCard"): operation = "GetExtendedAgentCard"
            default:
                let segments = path.split(separator: "/", omittingEmptySubsequences: false)
                guard segments.count >= 3, segments[0].isEmpty, segments[1] == "tasks", !segments[2].isEmpty else {
                    return Self.restError(code: -32601, message: "Unknown A2A REST operation")
                }
                var taskID = String(segments[2])
                if segments.count == 3 {
                    if method == "POST", taskID.hasSuffix(":cancel") {
                        taskID = String(taskID.dropLast(7)); operation = "CancelTask"
                    } else if method == "POST", taskID.hasSuffix(":subscribe") {
                        taskID = String(taskID.dropLast(10)); operation = "SubscribeToTask"
                    } else if method == "GET" { operation = "GetTask" }
                    else { return Self.restError(code: -32601, message: "Unsupported method") }
                    if let bodyID = params["id"] as? String, bodyID != taskID {
                        return Self.restError(code: -32602, message: "Task ID does not match URL")
                    }
                    params["id"] = taskID
                } else if segments[3] == "pushNotificationConfigs", (4...5).contains(segments.count) {
                    switch (method, segments.count) {
                    case ("POST", 4): operation = "CreateTaskPushNotificationConfig"
                    case ("GET", 4): operation = "ListTaskPushNotificationConfigs"
                    case ("GET", 5): operation = "GetTaskPushNotificationConfig"
                    case ("DELETE", 5): operation = "DeleteTaskPushNotificationConfig"
                    default: return Self.restError(code: -32601, message: "Unsupported method")
                    }
                    if let bodyID = params["taskId"] as? String, bodyID != taskID {
                        return Self.restError(code: -32602, message: "Task ID does not match URL")
                    }
                    params["taskId"] = taskID
                    if segments.count == 5 {
                        guard !segments[4].isEmpty else { return Self.restError(code: -32602, message: "Config ID required") }
                        params["id"] = String(segments[4])
                    }
                } else { return Self.restError(code: -32601, message: "Unknown A2A REST operation") }
            }
            let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "rest", "method": operation, "params": params], options: [.sortedKeys])
            switch await handle(request, principal: principal, version: version ?? "1.0") {
            case .stream(_, let events, _): return .stream(events)
            case .json(let envelope):
                if let error = envelope["error"] as? [String: Any] {
                    return Self.restError(code: error["code"] as? Int ?? -32603, message: error["message"] as? String ?? "Request failed")
                }
                return .json(200, envelope["result"] as? [String: Any] ?? [:])
            }
        } catch {
            return Self.restError(code: -32700, message: "Invalid JSON")
        }
    }

    static func restError(code: Int, message: String) -> RESTResponse {
        let mapping: (Int, String, String)
        switch code {
        case -32001: mapping = (404, "NOT_FOUND", "TASK_NOT_FOUND")
        case -32002: mapping = (400, "FAILED_PRECONDITION", "TASK_NOT_CANCELABLE")
        case -32003: mapping = (400, "FAILED_PRECONDITION", "PUSH_NOTIFICATION_NOT_SUPPORTED")
        case -32004: mapping = (400, "UNIMPLEMENTED", "UNSUPPORTED_OPERATION")
        case -32005: mapping = (400, "INVALID_ARGUMENT", "CONTENT_TYPE_NOT_SUPPORTED")
        case -32006: mapping = (400, "INVALID_ARGUMENT", "INVALID_AGENT_RESPONSE")
        case -32007: mapping = (404, "NOT_FOUND", "EXTENDED_AGENT_CARD_NOT_CONFIGURED")
        case -32008: mapping = (400, "FAILED_PRECONDITION", "EXTENSION_SUPPORT_REQUIRED")
        case -32009: mapping = (400, "INVALID_ARGUMENT", "VERSION_NOT_SUPPORTED")
        case -32601: mapping = (404, "UNIMPLEMENTED", "METHOD_NOT_FOUND")
        case -32603: mapping = (500, "INTERNAL", "INTERNAL_ERROR")
        default: mapping = (400, "INVALID_ARGUMENT", "INVALID_PARAMS")
        }
        return .json(mapping.0, ["error": ["code": mapping.0, "status": mapping.1, "message": message,
            "details": [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": mapping.2, "domain": "a2a-protocol.org"]]]])
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
