import Foundation
import PersistenceCore

/// Bounded SSE evidence folded into the same result as send/get. No replay and
/// no completion inferred from EOF, lastChunk, or the legacy `final` field.
public enum AgentA2AStream {
    public static func events(in data: Data) throws -> [JSONValue] {
        guard data.count <= AgentPeerHTTP.maximumResponseBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw AgentA2AWire.WireError.invalid("unreadable stream")
        }
        let frames = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
        return try frames.dropLast().compactMap { frame in
            let lines = frame.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map {
                let value = String($0.dropFirst(5))
                return value.hasPrefix(" ") ? String(value.dropFirst()) : value
            }
            guard !lines.isEmpty else { return nil }
            return try JSONValue.parse(Data(lines.joined(separator: "\n").utf8))
        }
    }

    public struct Receipt: Sendable {
        public let result: AgentA2AWire.Result?
        public let interrupted: Bool
    }

    public static func normalize(_ events: [JSONValue], interface: AgentA2AWire.Interface,
                                 requestID: String?, expectedTaskID: String? = nil) throws -> Receipt {
        var latest: AgentA2AWire.Result?
        var task: [String: JSONValue]?
        let legacy = interface.version == "0.3"
        for event in events {
            guard case .object(var payload) = event else { throw AgentA2AWire.WireError.invalid("stream event") }
            if interface.binding == "JSONRPC" {
                guard payload["jsonrpc"] == .string("2.0"), let requestID,
                      payload["id"] == .string(requestID), payload["error"] == nil,
                      case .object(let result)? = payload["result"] else {
                    throw AgentA2AWire.WireError.invalid("stream response was not confirmed")
                }
                payload = result
            }
            guard latest?.kind != "message", latest?.terminal != true,
                  latest?.needsInput != true, latest?.needsAuthentication != true else {
                throw AgentA2AWire.WireError.invalid("event after stream outcome")
            }
            let kind: String
            if legacy, case .string(let value)? = payload["kind"] { kind = value }
            else {
                let keys = ["task", "message", "statusUpdate", "artifactUpdate"].filter { payload[$0] != nil }
                guard keys.count == 1, case .object(let content)? = payload[keys[0]] else {
                    throw AgentA2AWire.WireError.invalid("ambiguous stream event")
                }
                kind = keys[0]; payload = content
            }
            switch kind {
            case "task":
                guard task == nil else { throw AgentA2AWire.WireError.invalid("duplicate initial task") }
                task = payload
            case "message":
                guard task == nil else { throw AgentA2AWire.WireError.invalid("mixed task and message stream") }
            case "status-update", "statusUpdate", "artifact-update", "artifactUpdate":
                guard var current = task, payload["taskId"] == current["id"],
                      payload["contextId"] == current["contextId"] else {
                    throw AgentA2AWire.WireError.invalid("stream task identity mismatch")
                }
                if kind == "status-update" || kind == "statusUpdate" {
                    current["status"] = payload["status"]
                } else {
                    guard case .object(var artifact)? = payload["artifact"], let id = artifact["artifactId"] else {
                        throw AgentA2AWire.WireError.invalid("stream artifact")
                    }
                    var artifacts: [JSONValue] = []
                    if case .array(let values)? = current["artifacts"] { artifacts = values }
                    if let index = artifacts.firstIndex(where: {
                        guard case .object(let value) = $0 else { return false }; return value["artifactId"] == id
                    }) {
                        if payload["append"] == .bool(true), case .object(let old) = artifacts[index],
                           case .array(let before)? = old["parts"], case .array(let after)? = artifact["parts"] {
                            artifact = old.merging(artifact) { _, new in new }
                            artifact["parts"] = .array(before + after)
                        }
                        artifacts[index] = .object(artifact)
                    } else { artifacts.append(.object(artifact)) }
                    current["artifacts"] = .array(artifacts)
                }
                task = current
            default: throw AgentA2AWire.WireError.invalid("unknown stream event")
            }
            let body = task ?? payload
            let result: JSONValue = legacy ? .object(body) : .object([task == nil ? "message" : "task": .object(body)])
            let wrapped: JSONValue = interface.binding == "JSONRPC"
                ? .object(["jsonrpc": .string("2.0"), "id": .string(requestID!), "result": result]) : result
            latest = try AgentA2AWire.normalizeResponse(wrapped, interface: interface,
                expectedRequestID: requestID, expectedTaskID: expectedTaskID)
        }
        let settled = latest.map { $0.kind == "message" || $0.terminal || $0.needsInput || $0.needsAuthentication } ?? false
        return Receipt(result: latest, interrupted: !settled)
    }
}
