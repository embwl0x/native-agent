import Foundation
import PersistenceCore
import ProviderRouting

/// A2A 1.0 and 0.3 wire projection. Endpoints, parts and metadata remain
/// untrusted data; the transport must authorize the destination and credentials.
public enum AgentA2AWire {
    public struct Interface: Sendable, Equatable {
        public let endpoint: URL
        public let version: String
        public let binding: String
        public let tenant: String?
        public let securityRequirements: JSONValue
        public let securitySchemes: JSONValue
        public let streaming: Bool
        public let extendedAgentCard: Bool
        public let pushNotifications: Bool
        public init(endpoint: URL, version: String, binding: String, tenant: String? = nil,
                    securityRequirements: JSONValue = .array([]), securitySchemes: JSONValue = .object([:]), streaming: Bool = false,
                    extendedAgentCard: Bool = false, pushNotifications: Bool = false) {
            self.endpoint = endpoint; self.version = version; self.binding = binding; self.tenant = tenant
            self.securityRequirements = securityRequirements; self.securitySchemes = securitySchemes
            self.streaming = streaming
            self.extendedAgentCard = extendedAgentCard; self.pushNotifications = pushNotifications
        }
    }

    public struct Request: Sendable, Equatable {
        public let url: URL
        public let httpMethod: String
        public let headers: [String: String]
        public let body: JSONValue?
        public let requestID: String?
        public var grpcMethod: String? = nil
        public var isStreaming: Bool {
            headers["Accept"] == "text/event-stream" || grpcMethod == "SendStreamingMessage" || grpcMethod == "SubscribeToTask"
        }
    }

    public struct Result: Sendable, Equatable {
        public let kind: String
        public let taskID: String?
        public let contextID: String?
        public let messageID: String?
        public let text: String
        public let parts: [JSONValue]
        public let artifacts: [JSONValue]
        public let state: String
        public let terminal: Bool
        /// True only for an explicitly completed task. A message is a reply,
        /// not evidence that a delegated action has completed.
        public let completed: Bool
        public let needsInput: Bool
        public let needsAuthentication: Bool
        public let raw: JSONValue
        public var failure: ProviderFailure.Report? = nil
    }

    public enum WireError: Error, LocalizedError, Equatable {
        case invalid(String)
        case unsupported(String)
        case remote(code: Int64, message: String)
        public var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Invalid A2A evidence: \(reason)"
            case .unsupported(let reason): return "Unsupported A2A interface: \(reason)"
            case .remote(let code, let message): return "A2A peer error \(code): \(message)"
            }
        }
    }

    public static func selectInterface(card: JSONValue, cardURL: URL) throws -> Interface {
        let card = try object(card, "agent card")
        if let capabilities = card["capabilities"] {
            let caps = try object(capabilities, "capabilities")
            for item in try array(caps["extensions"], "extensions") {
                let ext = try object(item, "extension")
                if let required = ext["required"] {
                    guard case .bool(let flag) = required else { throw WireError.invalid("extension required must be boolean") }
                    if flag { throw WireError.unsupported("required extension \(try optionalString(ext["uri"], "extension URI") ?? "unspecified")") }
                }
            }
        }
        let requirements = card["securityRequirements"] ?? card["security"] ?? .array([])
        _ = try array(requirements, "security requirements")
        let schemes = card["securitySchemes"] ?? .object([:])
        _ = try object(schemes, "security schemes")
        var candidates: [[String: JSONValue]] = []
        if let supported = card["supportedInterfaces"] {
            candidates = try array(supported, "supportedInterfaces").map { try object($0, "interface") }
        } else {
            let version = try requiredString(card["protocolVersion"], "protocolVersion")
            guard canonicalVersion(version) == "0.3" else { throw WireError.unsupported("legacy card protocol \(version)") }
            candidates.append(["url": card["url"] ?? .null, "protocolVersion": .string(version),
                               "protocolBinding": card["preferredTransport"] ?? .string("JSONRPC")])
            for item in try array(card["additionalInterfaces"], "additionalInterfaces") {
                let entry = try object(item, "additional interface")
                candidates.append(["url": entry["url"] ?? .null, "protocolVersion": .string(version),
                                   "protocolBinding": entry["transport"] ?? .null])
            }
        }
        // The card's declared order is the peer's protocol/binding preference.
        for entry in candidates {
            let advertised = try requiredString(entry["protocolVersion"], "interface protocolVersion")
            let binding = try requiredString(entry["protocolBinding"], "interface protocolBinding")
            guard let version = canonicalVersion(advertised),
                  binding == "JSONRPC" || (version == "1.0" && ["HTTP+JSON", "GRPC"].contains(binding)) else { continue }
            let address = try requiredString(entry["url"], "interface URL")
            guard var url = URL(string: address), let scheme = url.scheme?.lowercased(),
                  ["https", "http"].contains(scheme), url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw WireError.invalid("interface requires an absolute HTTP(S) URL without embedded credentials or fragment")
            }
            // Local servers commonly publish "localhost" even when their card
            // was fetched by literal address. Keep that interface on the exact
            // loopback address that answered; never resolve the hostname.
            if url.host?.lowercased() == "localhost",
               ["127.0.0.1", "::1", "[::1]"].contains(cardURL.host ?? ""),
               url.scheme == cardURL.scheme, (url.port == cardURL.port || binding == "GRPC"),
               var local = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                local.host = cardURL.host
                if let pinned = local.url { url = pinned }
            }
            return Interface(endpoint: url, version: version, binding: binding,
                             tenant: try optionalString(entry["tenant"], "tenant"),
                             securityRequirements: version == "0.3" ? (card["security"] ?? requirements) : requirements, securitySchemes: schemes,
                             streaming: (try? object(card["capabilities"] ?? .null, "capabilities"))?["streaming"] == .bool(true),
                             extendedAgentCard: (try? object(card["capabilities"] ?? .null, "capabilities"))?["extendedAgentCard"] == .bool(true),
                             pushNotifications: (try? object(card["capabilities"] ?? .null, "capabilities"))?["pushNotifications"] == .bool(true))
        }
        throw WireError.unsupported("no advertised supported version/binding pair")
    }

    public static func messageRequest(text: String, messageID: String, contextID: String? = nil,
                                      taskID: String? = nil, interface: Interface,
                                      requestID: String? = nil, streaming: Bool = false,
                                      pushConfiguration: JSONValue? = nil) throws -> Request {
        try validate(interface)
        guard !streaming || interface.streaming else { throw WireError.unsupported("streaming was not offered") }
        _ = try requiredString(.string(messageID), "messageId")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WireError.invalid("empty message") }
        let legacy = interface.version == "0.3"
        var message: [String: JSONValue] = ["messageId": .string(messageID), "role": .string(legacy ? "user" : "ROLE_USER"),
            "parts": .array([try wirePart(.object(["text": .string(text)]), version: interface.version)])]
        if legacy { message["kind"] = .string("message") }
        if let contextID { message["contextId"] = .string(try requiredString(.string(contextID), "contextId")) }
        if let taskID { message["taskId"] = .string(try requiredString(.string(taskID), "taskId")) }
        var params: [String: JSONValue] = ["message": .object(message)]
        if !streaming { params["configuration"] = .object(legacy ? ["blocking": .bool(false)] : ["returnImmediately": .bool(true)]) }
        if let pushConfiguration {
            try validatePushConfiguration(pushConfiguration, interface: interface)
            var configuration = (try? object(params["configuration"] ?? .object([:]), "configuration")) ?? [:]
            configuration["taskPushNotificationConfig"] = pushConfiguration
            params["configuration"] = .object(configuration)
        }
        if let tenant = interface.tenant { params["tenant"] = .string(tenant) }
        let method = streaming ? (legacy ? "message/stream" : "SendStreamingMessage") : (legacy ? "message/send" : "SendMessage")
        return try request(interface: interface, method: method, params: params,
                           requestID: requestID ?? messageID, taskID: nil)
    }

    public static func cancelRequest(taskID: String, interface: Interface, requestID: String = UUID().uuidString) throws -> Request {
        try validate(interface)
        var params: [String: JSONValue] = ["id": .string(try requiredString(.string(taskID), "taskId"))]
        if let tenant = interface.tenant { params["tenant"] = .string(tenant) }
        return try request(interface: interface, method: interface.version == "0.3" ? "tasks/cancel" : "CancelTask",
                           params: params, requestID: requestID, taskID: taskID)
    }

    public static func taskRequest(taskID: String, interface: Interface, requestID: String = UUID().uuidString) throws -> Request {
        try validate(interface)
        _ = try requiredString(.string(taskID), "taskId")
        var params: [String: JSONValue] = ["id": .string(taskID)]
        if let tenant = interface.tenant { params["tenant"] = .string(tenant) }
        return try request(interface: interface, method: interface.version == "0.3" ? "tasks/get" : "GetTask",
                           params: params, requestID: requestID, taskID: taskID)
    }

    private static func request(interface: Interface, method: String, params: [String: JSONValue], requestID: String, taskID: String?) throws -> Request {
        if interface.binding == "GRPC" {
            return Request(url: interface.endpoint, httpMethod: "POST", headers: [:],
                           body: .object(params), requestID: nil, grpcMethod: method)
        }
        let rpc = interface.binding == "JSONRPC"
        let streaming = ["message/stream", "SendStreamingMessage"].contains(method)
        let cancelling = ["tasks/cancel", "CancelTask"].contains(method)
        let headers = ["Content-Type": rpc ? "application/json" : "application/a2a+json",
                       "Accept": streaming ? "text/event-stream" : (rpc ? "application/json" : "application/a2a+json"), "A2A-Version": interface.version]
        if rpc {
            _ = try requiredString(.string(requestID), "request ID")
            return Request(url: interface.endpoint, httpMethod: "POST", headers: headers,
                           body: .object(["jsonrpc": .string("2.0"), "id": .string(requestID),
                                          "method": .string(method), "params": .object(params)]), requestID: requestID)
        }
        guard var components = URLComponents(url: interface.endpoint, resolvingAgainstBaseURL: false) else { throw WireError.invalid("endpoint URL") }
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        if let taskID {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
            guard let encoded = taskID.addingPercentEncoding(withAllowedCharacters: safe), taskID != ".", taskID != ".." else { throw WireError.invalid("task path identifier") }
            components.percentEncodedPath = base + "/tasks/" + encoded + (cancelling ? ":cancel" : "")
            if !cancelling, let tenant = interface.tenant { components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "tenant", value: tenant)] }
        } else { components.percentEncodedPath = base + (streaming ? "/message:stream" : "/message:send") }
        guard let url = components.url else { throw WireError.invalid("request URL") }
        return Request(url: url, httpMethod: taskID == nil || cancelling ? "POST" : "GET", headers: headers,
                       body: taskID == nil || cancelling ? .object(params) : nil, requestID: nil)
    }

    public static func normalizeResponse(_ value: JSONValue, interface: Interface,
                                         expectedRequestID: String? = nil, expectedTaskID: String? = nil) throws -> Result {
        try validate(interface)
        var payload = try object(value, "response")
        if interface.binding == "JSONRPC" {
            guard payload["jsonrpc"] == .string("2.0"), let expectedRequestID,
                  payload["id"] == .string(expectedRequestID) else { throw WireError.invalid("JSON-RPC response ID/version mismatch or missing expected ID") }
            guard (payload["result"] != nil) != (payload["error"] != nil) else { throw WireError.invalid("response must contain exactly one result or error") }
            if let error = payload["error"] {
                let error = try object(error, "RPC error")
                guard case .int(let code)? = error["code"] else { throw WireError.invalid("RPC error code") }
                throw WireError.remote(code: code, message: try requiredString(error["message"], "RPC error message"))
            }
            payload = try object(payload["result"]!, "RPC result")
        }
        let legacy = interface.version == "0.3"
        let kind: String
        if legacy { kind = try requiredString(payload["kind"], "result kind") }
        else if payload["task"] != nil || payload["message"] != nil {
            guard (payload["task"] != nil) != (payload["message"] != nil) else { throw WireError.invalid("ambiguous send response") }
            kind = payload["task"] != nil ? "task" : "message"
            payload = try object(payload[kind]!, kind)
        } else if expectedTaskID != nil { kind = "task" } // GetTask returns a Task directly.
        else { throw WireError.invalid("send response has no task or message") }
        var parts: [JSONValue] = []
        var artifacts: [JSONValue] = []
        var messageID: String?
        let contextID = try optionalString(payload["contextId"], "contextId")
        var taskID: String?
        var state = "reply"
        if kind == "message" {
            messageID = try validateMessage(payload, legacy: legacy)
            taskID = try optionalString(payload["taskId"], "taskId")
            parts = try array(payload["parts"], "message parts", required: true)
        } else if kind == "task" {
            taskID = try requiredString(payload["id"], "task ID")
            let status = try object(payload["status"] ?? .null, "task status")
            let wireState = try requiredString(status["state"], "task state")
            state = canonicalState(wireState, version: interface.version)
            if let message = status["message"] {
                let message = try object(message, "status message")
                messageID = try validateMessage(message, legacy: legacy)
                parts = try array(message["parts"], "status message parts", required: true)
            }
            artifacts = try array(payload["artifacts"], "artifacts")
            for artifact in artifacts {
                let artifact = try object(artifact, "artifact")
                _ = try requiredString(artifact["artifactId"], "artifact ID")
                let artifactParts = try array(artifact["parts"], "artifact parts", required: true)
                try validateParts(artifactParts, legacy: legacy)
            }
        } else { throw WireError.invalid("unsupported response kind \(kind)") }
        if let expectedTaskID, taskID != expectedTaskID { throw WireError.invalid("task identity mismatch") }
        try validateParts(parts, legacy: legacy)
        let outputParts = parts + artifacts.flatMap { item -> [JSONValue] in
            guard case .object(let object) = item, case .array(let parts)? = object["parts"] else { return [] }; return parts
        }
        let text = outputParts.compactMap { part -> String? in
            guard case .object(let object) = part, case .string(let text)? = object["text"] else { return nil }; return text
        }.joined(separator: "\n")
        var result = Result(kind: kind, taskID: taskID, contextID: contextID, messageID: messageID, text: text,
                      parts: parts, artifacts: artifacts, state: state,
                      terminal: ["completed", "failed", "canceled", "rejected"].contains(state), completed: state == "completed",
                      needsInput: state == "input-required", needsAuthentication: state == "auth-required", raw: value)
        if case .object(let status)? = payload["status"], case .object(let message)? = status["message"],
           case .object(let metadata)? = message["metadata"], let failure = metadata["provider_failure"],
           let data = try? failure.serializedData(pretty: false) {
            result.failure = try? JSONDecoder().decode(ProviderFailure.Report.self, from: data)
        }
        return result
    }

    private static func validateMessage(_ message: [String: JSONValue], legacy: Bool) throws -> String {
        if legacy && message["kind"] != .string("message") { throw WireError.invalid("message kind") }
        guard message["role"] == .string(legacy ? "agent" : "ROLE_AGENT") else { throw WireError.invalid("peer message role") }
        return try requiredString(message["messageId"], "message ID")
    }
    private static func validateParts(_ parts: [JSONValue], legacy: Bool) throws {
        for part in parts {
            _ = try canonicalPart(part, version: legacy ? "0.3" : "1.0")
        }
    }
    private static func canonicalVersion(_ version: String) -> String? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let pair = pieces.prefix(2).joined(separator: ".")
        return ["1.0", "0.3"].contains(pair) ? pair : nil
    }
    private static func validate(_ interface: Interface) throws {
        guard ["1.0", "0.3"].contains(interface.version), interface.binding == "JSONRPC" || (interface.version == "1.0" && ["HTTP+JSON", "GRPC"].contains(interface.binding)) else { throw WireError.unsupported("version/binding") }
    }
    private static func object(_ value: JSONValue, _ name: String) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw WireError.invalid("\(name) must be an object") }; return object
    }
    private static func array(_ value: JSONValue?, _ name: String, required: Bool = false) throws -> [JSONValue] {
        guard let value else { if required { throw WireError.invalid("missing \(name)") }; return [] }
        guard case .array(let array) = value else { throw WireError.invalid("\(name) must be an array") }; return array
    }
    private static func requiredString(_ value: JSONValue?, _ name: String) throws -> String {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WireError.invalid("missing or invalid \(name)") }; return text
    }
    private static func optionalString(_ value: JSONValue?, _ name: String) throws -> String? {
        guard let value else { return nil }; return try requiredString(value, name)
    }
}
