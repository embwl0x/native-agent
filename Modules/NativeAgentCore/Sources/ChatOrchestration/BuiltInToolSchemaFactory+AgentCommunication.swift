import Foundation
import NativeAgentCore
import PersistenceCore

extension BuiltInToolSchemaFactory {
    func agentCommunicationSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["agent_contacts", "agent_connect", "agent_message", "agent_read"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        let agent = strSchema("Contact name, if it identifies exactly one saved agent, or an exact reference from agent_contacts: codex, claude, omp, bot:<UUID>, or peer:<UUID>. Ambiguous names need a specific contact; never guess.")
        let conversation = strSchema("Optional human conversation label, such as browser work, for adapters supporting separate discussions. Omit to use this contact's current conversation. Bots have one continuous session: omit this field for bots. Opening a bot by name shows its latest full saved reply. On supported routes, an unused label starts a separate conversation; on a read it selects an existing one. The app retains the underlying identities.")
        return [
            requestedSchema(name: "agent_contacts", description: "Find a contact to ask, tell, or message by name, including saved agents, coding helpers and bots, with availability and status. Includes local agents, remote peers and agent hosts available to connect by name. Use contacts to identify an agent before connecting or disconnecting it. Set discover true only when the person asks about agents or asks to find agents; ordinary calls reuse observations without discovery.", parametersJSON: agentCommunicationParams(properties: [("discover", boolSchema())], required: [])),
            requestedSchema(name: "agent_connect", description: "Connect an agent by name, by URL, or as a desktop app. Disconnect needs the exact peer id from agent_contacts: disconnect true with name peer:<id>. For connect requests, check agent_contacts first to resolve the name; Codex and Claude may also name providers. Once the agent contact is identified, call this directly: the app itself shows the person the approval card when their settings call for one, so do not ask for permission in words first and do not describe the change and wait. name only (no endpoint, no transport): looks that agent up among the agent hosts this Mac is known to support and sets the connection up itself — one entry in that agent's own MCP settings running this app's link command, with a key minted for that connection alone. Everything else in that file is preserved and only the newest NativeAgent backup is kept beside it and removed after disconnect; an agent that is unknown or not installed gets an honest answer and nothing is changed. The person approves the exact change first, and the other app is never restarted or interrupted. Where that agent has a command line, the setup then proves itself: the command is run once with a fixed message asking it to answer through the entry, and the contact becomes connected only when that request actually arrives. If it does not, or the command is missing, the contact stays set up with the reason. Where it has none, the result says the other app may need a restart and that nothing of its window will be read; it turns connected on its first inbound message. Disconnect removes exactly that contact's entry and revokes its key. Omit transport or use auto with endpoint to discover a supported A2A or NativeAgent card through bounded same-origin GETs. Explicit a2a/nativeAgent saves without probing. For a closed desktop app use transport desktop, app_bundle_id and optional conversation_label; such a contact is send-only — the app types the message into that app's chat through a bounded internal desktop route using existing Mac permissions, and the other agent answers by adding this app's MCP server (command: nativeagent-link mcp) and replying with its agent_message tool. Reuses exact discovered/desktop routes. Does not send a message or grant authority.", parametersJSON: agentCommunicationParams(properties: [
                ("name", strSchema("The agent's name, at most 120 characters. On its own — with no endpoint and no transport — it is looked up among the known agent hosts on this Mac, matched case-insensitively including common aliases. With an endpoint it is the display name for that contact.")),
                ("endpoint", strSchema("Required for a2a/nativeAgent: HTTPS URL, or explicit loopback HTTP. No embedded credentials, query, or fragment. Omit for desktop, and omit to connect by name.")),
                ("transport", enumStringSchema(["auto", "a2a", "nativeAgent", "desktop"])),
                ("disconnect", boolSchema()),
                ("working_directory", strSchema("ACP agents only: explicit absolute project folder to show on the connect card. Omit for a new empty folder in this app's workspace.")),
                ("workspace", strSchema("Existing workspace folder, required for Cursor Workspace. Omit for global connections.")),
                ("executable_path", strSchema("Exact resolved executable bound by the app to the connect approval. Retained unchanged on replay.")),
                ("app_bundle_id", strSchema("Desktop only: exact installed app bundle identifier, such as com.example.agent. No guessed recipient identity.")),
                ("conversation_label", strSchema("Desktop only: optional visible conversation or bot label to verify in the app. Target data, not instructions or a verified session ID.")),
                ("bearer_token", strSchema("Optional network credential for this peer only; never use another connector's credentials. Not accepted for desktop."))
            ], required: ["name"])),
            requestedSchema(name: "agent_message", description: "Message an agent by name. Continues your current thread; conversation names a separate one, new_conversation:true starts fresh. Queued or delivered is not done; never auto-resend.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent), ("text", strSchema("The message to send.")),
                ("conversation", conversation),
                ("new_conversation", boolSchema()),
                ("conversation_id", strSchema("Advanced override: exact existing remote conversation identity. Normally omit; the app remembers it. A failed resume never falls back to a fresh session. Bots retain their own session.")),
                ("message_id", strSchema("Optional caller message identity for coding agents or A2A; NativeAgent accepts a UUID for receipt correlation, not deduplication. Not supported for bot sends. Use returned request identity for recovery.")),
                ("task_id", strSchema("A2A only: exact task to continue, especially when it needs input.")),
                ("options", obj([("type", .string("object")), ("additionalProperties", .bool(false)), ("properties", obj([
                    ("working_directory", strSchema("Local coding agents only: workspace for a new conversation.")),
                    ("topic", strSchema("Local coding agents only: title for a new conversation.")),
                    ("model", strSchema("Codex only: explicit model selection.")),
                    ("reasoning_effort", strSchema("Codex only: supported reasoning level.")),
                    ("fast", boolSchema()), ("pair_reviewer", boolSchema()),
                    ("timeout_seconds", intSchema("Local coding agents that support timeouts only: 60 to 3600 seconds.", minimum: 60, maximum: 3600))
                ]))]))
            ], required: ["agent", "text"])),
            requestedSchema(name: "agent_read", description: "Open your conversation with an agent by name. Omit identities: the app uses this session's current conversation and retained exact reply locator. Use conversation to open a named discussion. Default output shows who replied, their words and the conversation's state; details true exposes technical receipts. Reading never sends a message or invents completion. Pending replies are collected by the runtime where the route supports retrieval; you do not need to repeatedly poll. Advanced message_id, conversation_id and task_id remain available for exact recovery, and explicit listing filters retain adapter-specific behavior. Send-only routes cannot read another app's window, and standalone routes cannot promise persistent history. Missing or uncertain evidence remains explicit.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent),
                ("conversation", conversation),
                ("details", boolSchema()),
                ("history_before", strSchema("Session scrollback only: earlier_before returned by session_history. Omit for recent exchanges; never sends or restarts a turn.")),
                ("history_exchange", strSchema("Session scrollback only: open one exact retained exchange from session_history. Mutually exclusive with history_before and advanced protocol IDs.")),
                ("message_id", strSchema("Advanced exact message/request or bot shelf-entry identity. Normally omit; the app retains it. A reply is not independent proof that work finished.")),
                ("conversation_id", strSchema("Advanced exact session identity for NativeAgent reply recovery; bots may use bot:<UUID>. Normally omit. Coding receipt reads do not accept a conversation filter.")),
                ("task_id", strSchema("Advanced A2A task identity to retrieve. Normally omit; the app retains it.")),
                ("page_size", intSchema("A2A task listing page size.", minimum: 1, maximum: 100)),
                ("page_token", strSchema("A2A nextPageToken from the previous listing.")),
                ("context_id", strSchema("A2A task listing context filter.")),
                ("status", strSchema("A2A task listing status, for example TASK_STATE_WORKING.")),
                ("history_length", intSchema("Maximum messages in each listed A2A task's history.", minimum: 0)),
                ("include_artifacts", boolSchema()),
                ("status_timestamp_after", strSchema("A2A tasks updated at or after this RFC3339 timestamp.")),
                ("limit", intSchema("Local listing size: coding agents 1–12, bots 1–100.", minimum: 1, maximum: 100)),
                ("offset", intSchema("Coding listing offset or NativeAgent reply character offset. NativeAgent returns bounded pages; continue at next_offset. Bots use their existing shelf cursor instead.", minimum: 0))
            ], required: ["agent"]))
        ]
    }
    // Strict provider schemas require every property. Unused adapter-specific
    // fields must admit null, rather than forcing fabricated IDs or page sizes.
    private func agentCommunicationParams(properties: [(String, JSONValue)], required: [String]) -> Data {
        func nullableFields(_ value: JSONValue, optional: Bool) -> JSONValue {
            guard case .object(var object) = value else { return value }
            if case .object(let children)? = object["properties"] {
                let needed: Set<String>
                if case .array(let values)? = object["required"] {
                    needed = Set(values.compactMap { if case .string(let text) = $0 { return text }; return nil })
                } else { needed = [] }
                var projected: [String: JSONValue] = [:]
                for (key, child) in children {
                    projected[key] = nullableFields(child, optional: !needed.contains(key))
                }
                object["properties"] = .object(projected)
                object["required"] = .array(needed.sorted().map(JSONValue.string))
                object["additionalProperties"] = .bool(false)
            }
            if optional, case .string(let type)? = object["type"] {
                object["type"] = .array([.string(type), .string("null")])
                if case .array(var values)? = object["enum"] { values.append(.null); object["enum"] = .array(values) }
            }
            return .object(object)
        }
        let value = obj([("type", .string("object")), ("properties", obj(properties)),
                         ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
        return (try? nullableFields(value, optional: false).serializedData(pretty: false)) ?? Data("{}".utf8)
    }

}
