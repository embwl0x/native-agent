import Foundation
import PersistenceCore

extension AgentA2AWire {
    /// Other 1.0 operations share the same canonical ProtoJSON dictionaries as
    /// message/task projection. No separate REST model is kept.
    public static func operationRequest(_ method: String, parameters: [String: JSONValue] = [:],
                                        interface: Interface, requestID: String = UUID().uuidString) throws -> Request {
        guard interface.version == "1.0", ["JSONRPC", "HTTP+JSON", "GRPC"].contains(interface.binding) else {
            throw WireError.unsupported("operation requires A2A 1.0")
        }
        var params = parameters
        if let tenant = interface.tenant { params["tenant"] = .string(tenant) }
        func identifier(_ key: String) throws -> String {
            guard case .string(let value)? = params[key], !value.isEmpty, value != ".", value != "..",
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_~"))) else {
                throw WireError.invalid("missing or invalid \(key)")
            }
            return encoded
        }
        let path: String
        let verb: String
        switch method {
        case "GetExtendedAgentCard": path = "/extendedAgentCard"; verb = "GET"
        case "ListTasks":
            try validateListParameters(params)
            path = "/tasks"; verb = "GET"
        case "SubscribeToTask":
            guard interface.streaming else { throw WireError.unsupported("streaming was not offered") }
            path = try "/tasks/" + identifier("id") + ":subscribe"; verb = "POST"
        case "CreateTaskPushNotificationConfig", "GetTaskPushNotificationConfig", "ListTaskPushNotificationConfigs", "DeleteTaskPushNotificationConfig":
            let collection = try "/tasks/" + identifier("taskId") + "/pushNotificationConfigs"
            if method == "CreateTaskPushNotificationConfig" {
                try validatePushConfiguration(.object(params), interface: interface)
                path = collection; verb = "POST"
            } else if method == "ListTaskPushNotificationConfigs" {
                path = collection; verb = "GET"
            } else {
                path = try collection + "/" + identifier("id")
                verb = method == "DeleteTaskPushNotificationConfig" ? "DELETE" : "GET"
            }
        default: throw WireError.unsupported("operation \(method)")
        }
        if interface.binding == "GRPC" {
            return Request(url: interface.endpoint, httpMethod: "POST", headers: [:],
                           body: .object(params), requestID: nil, grpcMethod: method)
        }
        let rpc = interface.binding == "JSONRPC"
        let headers = ["Content-Type": rpc ? "application/json" : "application/a2a+json",
                       "Accept": method == "SubscribeToTask" ? "text/event-stream" : (rpc ? "application/json" : "application/a2a+json"),
                       "A2A-Version": interface.version]
        if rpc {
            return Request(url: interface.endpoint, httpMethod: "POST", headers: headers,
                           body: .object(["jsonrpc": .string("2.0"), "id": .string(requestID), "method": .string(method), "params": .object(params)]), requestID: requestID)
        }
        guard var url = URLComponents(url: interface.endpoint, resolvingAgainstBaseURL: false) else { throw WireError.invalid("endpoint") }
        let base = url.percentEncodedPath.hasSuffix("/") ? String(url.percentEncodedPath.dropLast()) : url.percentEncodedPath
        url.percentEncodedPath = base + path
        if verb != "POST" {
            let pathKeys: Set<String> = method.contains("PushNotificationConfig") ? ["taskId", "id"] : []
            url.queryItems = try (url.queryItems ?? []) + params.keys.sorted().filter { !pathKeys.contains($0) }.map { key in
                let text: String
                switch params[key]! {
                case .string(let value): text = value
                case .int(let value): text = String(value)
                case .bool(let value): text = value ? "true" : "false"
                default: throw WireError.invalid("query parameter \(key)")
                }
                return URLQueryItem(name: key, value: text)
            }
        }
        guard let endpoint = url.url else { throw WireError.invalid("request URL") }
        return Request(url: endpoint, httpMethod: verb, headers: headers, body: verb == "POST" ? .object(params) : nil, requestID: nil)
    }

    public static func operationResult(_ value: JSONValue, interface: Interface, requestID: String?) throws -> JSONValue {
        guard interface.binding == "JSONRPC" else {
            if case .object(let object) = value, let error = object["error"] {
                guard case .object(let fields) = error, case .int(let code)? = fields["code"],
                      case .string(let message)? = fields["message"] else { throw WireError.invalid("REST error") }
                throw WireError.remote(code: code, message: message)
            }
            return value
        }
        guard case .object(let envelope) = value, envelope["jsonrpc"] == .string("2.0"),
              let requestID, envelope["id"] == .string(requestID),
              (envelope["result"] != nil) != (envelope["error"] != nil) else { throw WireError.invalid("JSON-RPC response identity") }
        if case .object(let error)? = envelope["error"], case .int(let code)? = error["code"], case .string(let message)? = error["message"] {
            throw WireError.remote(code: code, message: message)
        }
        guard let result = envelope["result"] else { throw WireError.invalid("RPC error") }
        return result
    }

    public static func normalizeTaskList(_ value: JSONValue, interface: Interface, requestID: String?) throws -> JSONValue {
        let result = try operationResult(value, interface: interface, requestID: requestID)
        guard case .object(let object) = result else { throw WireError.invalid("task listing") }
        let tasks: [JSONValue]
        if case .array(let values)? = object["tasks"] { tasks = values }
        else if object["tasks"] == nil { tasks = [] } else { throw WireError.invalid("tasks") }
        // Validate each task through the existing canonical task mapping.
        for task in tasks {
            guard case .object(let row) = task, case .string(let id)? = row["id"] else { throw WireError.invalid("listed task ID") }
            let direct = Interface(endpoint: interface.endpoint, version: "1.0", binding: "HTTP+JSON")
            _ = try normalizeResponse(task, interface: direct, expectedTaskID: id)
        }
        for key in ["pageSize", "totalSize"] {
            if let value = object[key] { guard case .int(let count) = value, count >= 0 else { throw WireError.invalid(key) } }
        }
        if let value = object["nextPageToken"] { guard case .string = value else { throw WireError.invalid("nextPageToken") } }
        return result
    }

    static func validateListParameters(_ params: [String: JSONValue]) throws {
        guard Set(params.keys).isSubset(of: ["tenant", "contextId", "status", "pageSize", "pageToken", "historyLength", "statusTimestampAfter", "includeArtifacts"]) else { throw WireError.invalid("ListTasks fields") }
        for (key, value) in params {
            switch key {
            case "pageSize": guard case .int(let size) = value, (1...100).contains(size) else { throw WireError.invalid(key) }
            case "historyLength": guard case .int(let size) = value, size >= 0 else { throw WireError.invalid(key) }
            case "includeArtifacts": guard case .bool = value else { throw WireError.invalid(key) }
            default: guard case .string = value else { throw WireError.invalid(key) }
            }
        }
    }

    public static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// NativeAgent's receiver is loopback-only. Never promise a callback to a
    /// remote peer; the caller must additionally supply a running receiver.
    public static func validatePushConfiguration(_ config: JSONValue, interface: Interface) throws {
        guard interface.version == "1.0", interface.pushNotifications else { throw WireError.unsupported("push notifications were not offered") }
        guard isLoopback(interface.endpoint), case .object(let object) = config,
              case .string(let address)? = object["url"], let url = URL(string: address), isLoopback(url) else {
            throw WireError.unsupported("this app's loopback webhook is reachable only by loopback peers; use streaming or task reads")
        }
        try AgentPeerHTTP.validateURL(url)
    }
}
