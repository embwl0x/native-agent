import Foundation
import PersistenceCore

/// Bounded SSE evidence folded into the same result as send/get. No replay and
/// no completion inferred from EOF, lastChunk, or the legacy `final` field.
public enum AgentA2AStream {
    public static func events(in data: Data) throws -> [JSONValue] {
        guard data.count <= AgentPeerHTTP.maximumResponseBytes else {
            throw AgentA2AWire.WireError.invalid("unreadable stream")
        }
        // Find complete frames in bytes so a split UTF-8 character in the
        // discarded tail cannot invalidate earlier evidence.
        var lineStart = data.startIndex
        var end = lineStart
        var index = lineStart
        while index < data.endIndex {
            if data[index] == 0x0A || data[index] == 0x0D {
                var next = index + 1
                if data[index] == 0x0D, next < data.endIndex, data[next] == 0x0A { next += 1 }
                if index == lineStart { end = next }
                lineStart = next; index = next
            } else { index += 1 }
        }
        guard let text = String(data: data[data.startIndex..<end], encoding: .utf8) else {
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

    /// Validated display snapshots: assembled artifact text, a direct message,
    /// and status progress notes, retained together for coalesced delivery.
    /// Never evidence; `normalize` alone decides the outcome.
    public struct LiveUpdate: Sendable {
        public var text: String?
        public var note: String?
    }

    public struct Receipt: Sendable {
        public let result: AgentA2AWire.Result?
        public let interrupted: Bool
    }

    public static func normalize(_ events: [JSONValue], interface: AgentA2AWire.Interface,
                                 requestID: String?, expectedTaskID: String? = nil) throws -> Receipt {
        var accumulator = Accumulator(interface: interface, requestID: requestID, expectedTaskID: expectedTaskID)
        for event in events { _ = try accumulator.receive(event) }
        return accumulator.receipt
    }

    /// Live publication and final evidence share identity, shape and artifact folding.
    struct Accumulator: Sendable {
        let interface: AgentA2AWire.Interface
        let requestID: String?
        let expectedTaskID: String?
        let bearerToken: String?
        private var latest: AgentA2AWire.Result?
        private var task: [String: JSONValue]?
        private var liveUpdate = LiveUpdate()

        init(interface: AgentA2AWire.Interface, requestID: String?, expectedTaskID: String? = nil, bearerToken: String? = nil) {
            self.interface = interface; self.requestID = requestID; self.expectedTaskID = expectedTaskID
            self.bearerToken = bearerToken
        }

        mutating func receive(_ event: JSONValue) throws -> LiveUpdate {
            let legacy = interface.version == "0.3"
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
                if legacy, task == nil {
                    guard case .string(let id)? = payload["taskId"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          case .string(let context)? = payload["contextId"], !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AgentA2AWire.WireError.invalid("stream task identity mismatch")
                    }
                    task = ["kind": .string("task"), "id": .string(id), "contextId": .string(context),
                            "status": .object(["state": .string("unknown")])]
                }
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
                           case .array(var before)? = old["parts"], case .array(var after)? = artifact["parts"] {
                            // Only the explicit append boundary joins text fragments;
                            // distinct parts within either update keep their separators.
                            if case .object(let tail)? = before.last, case .string(let prefix)? = tail["text"],
                               case .object(let head)? = after.first, case .string(let suffix)? = head["text"] {
                                _ = try AgentA2AWire.canonicalPart(.object(head), version: interface.version)
                                var joined = tail.merging(head) { _, new in new }
                                joined["text"] = .string(prefix + suffix)
                                before[before.count - 1] = .object(joined)
                                after.removeFirst()
                            }
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
            let response: JSONValue = legacy ? .object(body) : .object([task == nil ? "message" : "task": .object(body)])
            let wrapped: JSONValue = interface.binding == "JSONRPC"
                ? .object(["jsonrpc": .string("2.0"), "id": .string(requestID!), "result": response]) : response
            latest = try AgentA2AWire.normalizeResponse(wrapped, interface: interface,
                expectedRequestID: requestID, expectedTaskID: expectedTaskID)
            let result = latest!
            var update = liveUpdate
            if result.kind == "message" { update.text = AgentPeerHTTP.redactLiveText(result.text, token: bearerToken) }
            else {
                if kind == "task" || kind == "artifact-update" || kind == "artifactUpdate" {
                    update.text = result.artifacts.compactMap { item -> String? in
                        guard case .object(let artifact) = item, case .array(let parts)? = artifact["parts"] else { return nil }
                        let textParts = parts.filter { if case .object(let part) = $0, case .string? = part["text"] { true } else { false } }
                        guard !textParts.isEmpty else { return nil }
                        // Each artifact has its own append boundary, even while others arrive.
                        return AgentPeerHTTP.redactLiveText(Self.text(textParts), token: bearerToken)
                    }.joined(separator: "\n")
                }
                if kind == "task" || kind == "status-update" || kind == "statusUpdate" {
                    let message = Self.text(result.parts)
                    let note: String
                    switch result.state {
                    case "submitted": note = "Request received."
                    case "working": note = "Working on your request."
                    case "input-required": note = "Waiting for your input."
                    case "auth-required": note = "Sign-in is needed to continue."
                    case "completed": note = "Task completed."
                    case "failed": note = "Task failed."
                    case "canceled": note = "Task canceled."
                    case "rejected": note = "Request declined."
                    default: note = "Task status is unknown."
                    }
                    update.note = AgentPeerHTTP.redactLiveText(message.isEmpty ? note : message, token: bearerToken)
                }
            }
            liveUpdate = update
            return update
        }

        private static func text(_ parts: [JSONValue]) -> String {
            parts.compactMap { part -> String? in
                guard case .object(let part) = part, case .string(let text)? = part["text"] else { return nil }
                return text
            }.joined(separator: "\n")
        }

        var receipt: Receipt {
            let settled = latest.map { $0.kind == "message" || $0.terminal || $0.needsInput || $0.needsAuthentication } ?? false
            return Receipt(result: latest, interrupted: !settled)
        }
    }
}
