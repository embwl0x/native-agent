import Foundation
import PersistenceCore

extension AgentA2AWire {
    /// The canonical content shape is 1.0 ProtoJSON. Both directions use this
    /// mapping; transport policy (file admission, size, fetching) stays outside.
    public static func canonicalPart(_ value: JSONValue, version: String) throws -> JSONValue {
        guard case .object(var part) = value else { throw WireError.invalid("part must be an object") }
        if version == "0.3" {
            guard case .string(let kind)? = part.removeValue(forKey: "kind") else { throw WireError.invalid("part kind") }
            switch kind {
            case "text":
                guard case .string? = part["text"] else { throw WireError.invalid("text part") }
            case "data":
                guard case .object? = part["data"] else { throw WireError.invalid("data part") }
            case "file":
                guard case .object(let file)? = part.removeValue(forKey: "file") else { throw WireError.invalid("file part") }
                part["raw"] = file["bytes"]; part["url"] = file["uri"]
                part["filename"] = file["name"]; part["mediaType"] = file["mimeType"]
            default: throw WireError.invalid("part kind")
            }
        }
        let content = ["text", "raw", "url", "data"].filter { part[$0] != nil }
        guard content.count == 1 else { throw WireError.invalid("part must contain exactly one content value") }
        if content[0] != "data", case .string? = part[content[0]] {} else if content[0] != "data" {
            throw WireError.invalid("part content must be a string")
        }
        return .object(part)
    }

    public static func wirePart(_ canonical: JSONValue, version: String) throws -> JSONValue {
        guard case .object(var part) = try canonicalPart(canonical, version: "1.0") else { throw WireError.invalid("part") }
        guard version == "0.3" else { return .object(part) }
        if part["text"] != nil { part["kind"] = .string("text") }
        else if let data = part["data"] {
            part["kind"] = .string("data")
            // Match the SDK compatibility projection: 0.3 data is an object.
            if case .object = data {} else { part["data"] = .object(["value": data]) }
        }
        else {
            var file: [String: JSONValue] = [:]
            file["bytes"] = part.removeValue(forKey: "raw"); file["uri"] = part.removeValue(forKey: "url")
            file["name"] = part.removeValue(forKey: "filename"); file["mimeType"] = part.removeValue(forKey: "mediaType")
            part["kind"] = .string("file"); part["file"] = .object(file)
        }
        return .object(part)
    }

    public static func canonicalState(_ value: String, version: String) -> String {
        let states = ["submitted", "working", "input-required", "auth-required", "completed", "failed", "canceled", "rejected", "unknown"]
        let candidate = version == "0.3" ? value : value.replacingOccurrences(of: "TASK_STATE_", with: "").lowercased().replacingOccurrences(of: "_", with: "-")
        return states.contains(candidate) && (version == "0.3" || value.hasPrefix("TASK_STATE_")) ? candidate : "unknown"
    }

    public static func wireState(_ state: String, version: String) -> String {
        version == "0.3" ? state : "TASK_STATE_" + state.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    /// Project an existing 0.3 task/message/event without traversing user data
    /// or metadata. The server retains one execution model for both versions.
    public static func canonicalObject(_ value: JSONValue) throws -> JSONValue {
        guard case .object(var object) = value else { throw WireError.invalid("object") }
        object.removeValue(forKey: "kind")
        object.removeValue(forKey: "final")
        if case .string(let role)? = object["role"] { object["role"] = .string(role == "user" ? "ROLE_USER" : "ROLE_AGENT") }
        if case .object(var status)? = object["status"] {
            if case .string(let state)? = status["state"] { status["state"] = .string(wireState(state, version: "1.0")) }
            if let message = status["message"] { status["message"] = try canonicalObject(message) }
            object["status"] = .object(status)
        }
        if case .array(let parts)? = object["parts"] {
            // Server data parts already hold protobuf Value, including scalars.
            object["parts"] = .array(try parts.map { part in
                if case .object(var data) = part, data["kind"] == .string("data") {
                    data.removeValue(forKey: "kind"); return try canonicalPart(.object(data), version: "1.0")
                }
                return try canonicalPart(part, version: "0.3")
            })
        }
        for key in ["artifacts", "history"] {
            if case .array(let values)? = object[key] { object[key] = .array(try values.map(canonicalObject)) }
        }
        if let artifact = object["artifact"] { object["artifact"] = try canonicalObject(artifact) }
        return .object(object)
    }
}
