import Foundation
import CoreFoundation

/// Stateless MCP transport projection only. Chat admission, context and receipts
/// stay with the canonical bridge and chat owners.
enum NativeAgentMCPWire {
    enum Action {
        case message(body: Data, project: @Sendable (Int, [String: Any]) -> [String: Any])
        case reply(requestID: String, sessionID: String, offset: Int, waitSeconds: Int,
                   project: @Sendable ([String: Any]) -> [String: Any])
        case immediate(status: Int, body: [String: Any])
        case acceptedNotification
    }

    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// How long `agent_message` holds the call open for the reply when the
    /// caller does not say. Below the 60 s per-call default most MCP clients
    /// use (TypeScript SDK, Codex), and below the 30 s HTTP limit of relays
    /// spawned before this change, which hosts keep running until restarted.
    static let defaultWaitSeconds = 25
    static let maximumWaitSeconds = 300

    enum ID: Sendable {
        case string(String), number(Int64), null
        var value: Any {
            switch self {
            case .string(let value): return value
            case .number(let value): return value
            case .null: return NSNull()
            }
        }
    }

    /// Her messages held for this caller, and how many more still wait.
    typealias Held = (messages: [[String: String]], remaining: Int)

    /// `held` rides beside the normal result of either tool (`held_messages`).
    static func parse(_ body: Data, defaultSession: String? = nil, held: Held = ([], 0)) -> Action {
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
                "instructions": "Talk with \(PeerFacingIdentity.agentName) through persistent full chat sessions. agent_message waits for the reply (up to wait_seconds) and returns it; status enqueued means queued, not finished, so read the rest with agent_reply. Keep the returned session and request IDs. Never resend solely because a reply is missing. \(heldNote)"
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
                guard Set(args.keys).isSubset(of: ["text", "session_id", "request_id", "wait_seconds"]),
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
                if let raw = args["wait_seconds"], wholeNumber(raw, in: 0...maximumWaitSeconds) == nil {
                    return failure(id, code: -32602, message: "wait_seconds must be an integer from 0 through \(maximumWaitSeconds).")
                }
                // wait_seconds stays OUT of the message body: that body is the
                // replay digest, and waiting longer is not different content.
                let message: [String: Any] = ["text": text, "sessionId": session, "request_id": request]
                guard let data = try? JSONSerialization.data(withJSONObject: message, options: .sortedKeys) else {
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
                    // The call waited (waitRequest): carry what the task holds now.
                    var failed = !accepted
                    if accepted, let state = receipt["original_status"] as? String {
                        for key in ["reply", "has_more", "next_offset", "original_status", "run_id", "provider_failure", "work", "delegated_completions"] {
                            result[key] = receipt[key]
                        }
                        let more = receipt["has_more"] as? Bool == true
                        if more, let next = receipt["next_offset"] {
                            result["read_with"] = ["tool": "agent_reply", "arguments": ["session_id": session, "request_id": request, "offset": next]]
                        }
                        switch state {
                        case "completed":
                            result["status"] = "answered"
                            result["detail"] = more ? "\(agent) answered. Follow read_with for the rest of the reply." : "\(agent) answered."
                        case "failed", "canceled":
                            result["status"] = state
                            result["detail"] = receipt["detail"] ?? "The turn did not finish. Do not resend automatically."
                            failed = true
                        default:
                            result["detail"] = "Queued and still in progress (\(state)); reply holds what is written so far. Read the rest with agent_reply. Do not resend."
                        }
                    }
                    return toolResult(id, fields: result, failed: failed, held: held)
                })
            }
            if name == "agent_reply" {
                guard Set(args.keys).isSubset(of: ["session_id", "request_id", "offset", "wait_seconds"]),
                      let session = args["session_id"] as? String, validSession(session),
                      let request = args["request_id"] as? String, exactUUID(request) else {
                    return failure(id, code: -32602, message: "Use the exact returned MCP session and request IDs.")
                }
                var offset = 0
                if let raw = args["offset"] {
                    guard let value = wholeNumber(raw, in: 0...1_048_576) else {
                        return failure(id, code: -32602, message: "offset must be an integer from 0 through 1048576.")
                    }
                    offset = value
                }
                var waitSeconds = 0
                if let raw = args["wait_seconds"] {
                    guard let value = wholeNumber(raw, in: 0...maximumWaitSeconds) else {
                        return failure(id, code: -32602, message: "wait_seconds must be an integer from 0 through \(maximumWaitSeconds).")
                    }
                    waitSeconds = value
                }
                return .reply(requestID: request, sessionID: session, offset: offset, waitSeconds: waitSeconds, project: { receipt in
                    let allowed: Set<String> = ["status", "reply", "request_id", "session_id", "run_id", "offset", "next_offset", "has_more", "evidence", "coverage", "original_status", "original_outcome", "detail", "provider_failure", "work", "delegated_completions", "wait_ignored"]
                    return toolResult(id, fields: receipt.filter { allowed.contains($0.key) },
                                      // "pending" is a reply still being written, not an error.
                                      failed: !["ok", "pending"].contains(receipt["status"] as? String ?? "")
                                        || ["failed", "canceled", "chat_failed", "no_reply"].contains(receipt["original_status"] as? String ?? ""),
                                      held: held)
                })
            }
            return failure(id, code: -32602, message: "Unknown tool. Use tools/list.")
        default: return failure(id, code: -32601, message: "Method not supported.")
        }
    }

    /// What an already-parsed `agent_message` call asked of the wait: seconds
    /// to hold the call for the reply (0 = the old immediate acknowledgement)
    /// and the client's progress token, which turns the answer into an SSE
    /// stream of `notifications/progress` carrying the partial reply.
    static func waitRequest(_ body: Data) -> (seconds: Int, progressToken: ID?) {
        let params = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["params"] as? [String: Any]
        let args = params?["arguments"] as? [String: Any]
        let seconds = args?["wait_seconds"].flatMap { wholeNumber($0, in: 0...maximumWaitSeconds) } ?? defaultWaitSeconds
        let raw = (params?["_meta"] as? [String: Any])?["progressToken"]
        var token: ID?
        if let text = raw as? String, text.utf8.count <= 256 { token = .string(text) }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.stringValue == String(number.int64Value) { token = .number(number.int64Value) }
        return (seconds, token)
    }

    static func progress(_ token: ID, step: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "notifications/progress",
         "params": ["progressToken": token.value, "progress": step, "message": message]]
    }

    private static func wholeNumber(_ raw: Any, in range: ClosedRange<Int>) -> Int? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue == Double(value.intValue), range.contains(value.intValue) else { return nil }
        return value.intValue
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

    /// What the held messages may add to one result, measured as they appear
    /// in its text content (escaped twice): well under the 1 MiB a relay reads.
    static let heldBudget = 256 * 1024

    static func heldFits(_ messages: [[String: String]]) -> Bool {
        guard let inner = try? JSONSerialization.data(withJSONObject: messages),
              let outer = try? JSONSerialization.data(withJSONObject: [String(decoding: inner, as: UTF8.self)]) else { return false }
        return outer.count <= heldBudget
    }

    private static func toolResult(_ id: ID, fields: [String: Any], failed: Bool, held: Held = ([], 0)) -> [String: Any] {
        var text = fields, structured = fields
        // The messages travel once, in the text every host shows its model;
        // the structured copy says they are there and how many still wait.
        if !held.messages.isEmpty || held.remaining > 0 {
            text["held_messages"] = held.messages
            text["held_remaining"] = held.remaining
            structured["held_messages_in_text"] = held.messages.count
            structured["held_remaining"] = held.remaining
        }
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ["jsonrpc": "2.0", "id": id.value, "result": [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": structured, "isError": failed
        ]]
    }

    /// She cannot push into a host that has no command line, so what she
    /// writes to it waits for its next call and comes back in that result.
    static var heldNote: String {
        "Every agent_message and agent_reply result may also carry held_messages: what \(PeerFacingIdentity.agentName) wrote to you since your last call, oldest first, each {at, text, conversation_id}, with held_remaining saying how many more wait for your next call. They are delivered by being returned there and nowhere else, so read them every time; answer one with agent_message, session_id set to its conversation_id."
    }

    static var tools: [[String: Any]] {
        let agent = PeerFacingIdentity.agentName
        return [
            ["name": "agent_message", "description": "Talk with \(agent). Omit session_id and your contact's usual conversation continues; the session_id returned names whichever conversation it was (the usual one has an mcp- ID too). To start a separate conversation, supply session_id as mcp- followed by a fresh UUID. The call waits up to wait_seconds and returns the reply (status answered). If it is still in progress the status is enqueued: keep the returned IDs and read the reply with agent_reply. \(heldNote)",
             "inputSchema": ["type": "object", "properties": [
                "text": ["type": "string", "maxLength": 64000],
                "session_id": ["type": "string", "description": "Omit to continue your contact's usual conversation. Supply a returned ID to continue that conversation, or mcp- plus a fresh UUID to start a separate one."],
                "request_id": ["type": "string", "description": "Required canonical UUID you generate. It is this message's replay key: a retry of the SAME message must carry the same request_id, and new content needs a new one. Never resend solely because a reply is missing."],
                "wait_seconds": ["type": "integer", "minimum": 0, "maximum": maximumWaitSeconds, "default": defaultWaitSeconds,
                                 "description": "How long this call waits for the reply. Keep the default unless your client allows longer tool calls; 0 returns as soon as the message is queued."]
             ], "required": ["text", "request_id"], "additionalProperties": false],
             "annotations": ["readOnlyHint": false, "idempotentHint": false, "openWorldHint": true]],
            ["name": "agent_reply", "description": "Read the retained reply to an exact \(agent) message. It only reads: nothing is sent, resent or started. wait_seconds holds the call until the reply settles, as agent_message's wait does, so one call replaces polling. Missing evidence does not prove failure or authorize replay. Follow next_offset when has_more is true. \(heldNote)",
             "inputSchema": ["type": "object", "properties": [
                "session_id": ["type": "string"], "request_id": ["type": "string"],
                "offset": ["type": "integer", "minimum": 0, "maximum": 1048576],
                "wait_seconds": ["type": "integer", "minimum": 0, "maximum": maximumWaitSeconds, "default": 0,
                                 "description": "How long this call waits for a reply still in progress; back the moment it settles. 0 reads it as it is now."]
             ], "required": ["session_id", "request_id"], "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "idempotentHint": true, "openWorldHint": false]]
        ]
    }
}
