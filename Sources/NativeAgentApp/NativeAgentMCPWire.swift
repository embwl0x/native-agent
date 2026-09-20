import Foundation
import CoreFoundation

/// Stateless MCP transport projection only. Chat admission, context and receipts
/// stay with ClaudeBridge and the ordinary app chat owners.
enum NativeAgentMCPWire {
    enum Action {
        case message(body: Data, project: @Sendable (Int, [String: Any]) -> [String: Any])
        case reply(requestID: String, sessionID: String, offset: Int,
                   project: @Sendable ([String: Any]) -> [String: Any])
        case immediate(status: Int, body: [String: Any])
        case acceptedNotification
    }

    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private enum ID: Sendable {
        case string(String), number(Int64), null
        var value: Any {
            switch self {
            case .string(let value): return value
            case .number(let value): return value
            case .null: return NSNull()
            }
        }
    }

    static func parse(_ body: Data, defaultSession: String? = nil) -> Action {
        guard body.count <= 100_000,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return failure(.null, code: -32700, message: "Expected one bounded JSON-RPC request.")
        }
        let id: ID
        if let text = json["id"] as? String, text.utf8.count <= 256 { id = .string(text) }
        else if let number = json["id"] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.stringValue == String(number.int64Value) { id = .number(number.int64Value) }
        else if json["id"] == nil { id = .null }
        else { return failure(.null, code: -32600, message: "Invalid request ID.") }
        guard json["jsonrpc"] as? String == "2.0", let method = json["method"] as? String else {
            return failure(id, code: -32600, message: "Expected JSON-RPC 2.0 method.")
        }
        if json["id"] == nil {
            // Notifications never start a turn, invoke tools or cancel work.
            return method.hasPrefix("notifications/") ? .acceptedNotification
                : failure(.null, code: -32600, message: "Requests require an ID.")
        }
        guard json["params"] == nil || json["params"] is [String: Any] else {
            return failure(id, code: -32602, message: "params must be an object.")
        }
        let params = json["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String,
                  params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else {
                return failure(id, code: -32602, message: "Initialization requires protocolVersion, capabilities and clientInfo.")
            }
            return success(id, result: [
                "protocolVersion": versions.contains(requested) ? requested : versions[0],
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "NativeAgent", "version": "1.0"],
                "instructions": "Talk with \(PeerFacingIdentity.agentName) through persistent full chat sessions. Keep the returned session and request IDs. A message acknowledgement means queued, not finished. Read the exact reply; never resend solely because a reply is missing."
            ])
        case "ping": return success(id, result: [:])
        case "tools/list":
            guard params["cursor"] == nil else {
                return failure(id, code: -32602, message: "This complete tool list has no cursor.")
            }
            return success(id, result: ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String,
                  let args = params["arguments"] as? [String: Any] else {
                return failure(id, code: -32602, message: "Tool name and arguments are required.")
            }
            if name == "agent_message" {
                guard Set(args.keys).isSubset(of: ["text", "session_id", "request_id"]),
                      let text = args["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 64000 else {
                    return failure(id, code: -32602, message: "Provide nonempty text up to 64000 UTF-8 bytes and optional session/request IDs.")
                }
                let session: String
                if let supplied = args["session_id"] {
                    guard let value = supplied as? String, validSession(value) else {
                        return failure(id, code: -32602, message: "Continue only the exact MCP session ID previously returned.")
                    }
                    session = value
                } else { session = defaultSession ?? "mcp-" + UUID().uuidString.lowercased() }
                // request_id is REQUIRED, and minting one here is exactly what
                // made it useless: it is the at-most-once claim key
                // (AgentPeerReplayClaimStore), so a server-minted id meant the
                // same JSON-RPC bytes, re-sent, claimed a fresh key and ran
                // the turn again. Only the caller can say "this is the same
                // message I already sent".
                guard let supplied = args["request_id"], let request = supplied as? String,
                      exactUUID(request) else {
                    return failure(id, code: -32602, message: "request_id is required and must be a canonical UUID. It is this message's replay key: retry the same message under the same request_id, and use a new one only for new content.")
                }
                let message: [String: Any] = ["text": text, "sessionId": session, "request_id": request]
                guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                    return failure(id, code: -32603, message: "Could not encode message.")
                }
                let agent = PeerFacingIdentity.agentName
                return .message(body: data, project: { status, receipt in
                    let accepted = status == 200 && receipt["ack"] as? String == "enqueued"
                        && receipt["sessionId"] as? String == session
                        && receipt["requestId"] as? String == request
                    var result: [String: Any] = [
                        "status": accepted ? "enqueued" : "outcome_unknown",
                        "session_id": session, "request_id": request,
                        "read_with": ["tool": "agent_reply", "arguments": ["session_id": session, "request_id": request]],
                        "detail": accepted ? "Durably queued for \(agent)'s full chat turn. Read the reply separately."
                            : "No successful enqueue acknowledgement. Read retained evidence before considering another send."
                    ]
                    if status >= 400 && status < 500 { result["status"] = "rejected" }
                    if !accepted, let detail = receipt["detail"] { result["detail"] = detail }
                    return toolResult(id, fields: result, failed: !accepted)
                })
            }
            if name == "agent_reply" {
                guard Set(args.keys).isSubset(of: ["session_id", "request_id", "offset"]),
                      let session = args["session_id"] as? String, validSession(session),
                      let request = args["request_id"] as? String, exactUUID(request) else {
                    return failure(id, code: -32602, message: "Use the exact returned MCP session and request IDs.")
                }
                var offset = 0
                if let raw = args["offset"] {
                    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                          value.doubleValue == Double(value.intValue), (0...1_048_576).contains(value.intValue) else {
                        return failure(id, code: -32602, message: "offset must be an integer from 0 through 1048576.")
                    }
                    offset = value.intValue
                }
                return .reply(requestID: request, sessionID: session, offset: offset, project: { receipt in
                    let allowed: Set<String> = ["status", "reply", "request_id", "session_id", "run_id", "offset", "next_offset", "has_more", "evidence", "coverage", "original_status", "original_outcome", "detail", "provider_failure", "work"]
                    return toolResult(id, fields: receipt.filter { allowed.contains($0.key) },
                                      failed: receipt["status"] as? String != "ok"
                                        || ["failed", "canceled", "chat_failed", "no_reply"].contains(receipt["original_status"] as? String ?? ""))
                })
            }
            return failure(id, code: -32602, message: "Unknown tool. Use tools/list.")
        default: return failure(id, code: -32601, message: "Method not supported.")
        }
    }

    static func validSession(_ value: String) -> Bool {
        value.hasPrefix("mcp-") && exactUUID(String(value.dropFirst(4)))
    }

    private static func exactUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value.lowercased()
    }

    private static func failure(_ id: ID, code: Int, message: String) -> Action {
        .immediate(status: 200, body: ["jsonrpc": "2.0", "id": id.value,
                                      "error": ["code": code, "message": message]])
    }

    private static func success(_ id: ID, result: [String: Any]) -> Action {
        .immediate(status: 200, body: ["jsonrpc": "2.0", "id": id.value, "result": result])
    }

    private static func toolResult(_ id: ID, fields: [String: Any], failed: Bool) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ["jsonrpc": "2.0", "id": id.value, "result": [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": fields, "isError": failed
        ]]
    }

    static var tools: [[String: Any]] {
        let agent = PeerFacingIdentity.agentName
        return [
            ["name": "agent_message", "description": "Talk with \(agent). Your contact's conversation continues automatically. To start a separate conversation, supply session_id as mcp- followed by a fresh UUID. Keep returned IDs to read the reply. The first answer confirms your message was queued.",
             "inputSchema": ["type": "object", "properties": [
                "text": ["type": "string", "maxLength": 64000],
                "session_id": ["type": "string", "description": "Omit to continue your contact's usual conversation. Supply a returned ID to continue a separate conversation, or mcp- plus a fresh UUID to start one."],
                "request_id": ["type": "string", "description": "Required canonical UUID you generate. It is this message's replay key: a retry of the SAME message must carry the same request_id, and new content needs a new one. Never resend solely because a reply is missing."]
             ], "required": ["text", "request_id"], "additionalProperties": false],
             "annotations": ["readOnlyHint": false, "idempotentHint": false, "openWorldHint": true]],
            ["name": "agent_reply", "description": "Read the retained reply to an exact \(agent) message. Missing evidence does not prove failure or authorize replay. Follow next_offset when has_more is true.",
             "inputSchema": ["type": "object", "properties": [
                "session_id": ["type": "string"], "request_id": ["type": "string"],
                "offset": ["type": "integer", "minimum": 0, "maximum": 1048576]
             ], "required": ["session_id", "request_id"], "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "idempotentHint": true, "openWorldHint": false]]
        ]
    }
}
