import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `BuiltInToolSchemaFactory+AgentCommunication.swift` | `BuiltInToolSchemaFactory`: `agentCommunicationSchemas` |

extension BuiltInToolSchemaFactory {
    func agentCommunicationSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["agent_contacts", "agent_connect", "agent_message", "agent_read", "agent_cancel"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        let agent = ToolSchema.strSchema("A unique saved participant name or handle, bot:<UUID>, or peer:<UUID> from agent.contacts. Ambiguous names need an exact reference; never guess.")
        let conversation = ToolSchema.strSchema("Optional human conversation label, such as browser work, for adapters supporting separate conversations. Omit to use this participant's current conversation. Home message shortcuts also take args {text, conversation}. Bots have one continuous conversation: omit this field for bots. Opening a bot by name shows its latest full saved reply. On supported routes, an unused label starts a separate conversation; on a read it selects an existing one. The app retains the underlying identities.")
        return [
            requestedSchema(name: "agent_contacts", toolClass: .read, description: "Find a participant by name: saved connections, coding helpers and bots, with availability and status. Includes local agents, remote peers and agent hosts available to connect by name. Set discover true only when the person asks about agents or asks to find agents; ordinary calls reuse observations without discovery.", parametersJSON: agentCommunicationParams(properties: [("discover", ToolSchema.obj([("anyOf", .array([ToolSchema.obj([("type", .string("boolean"))]), ToolSchema.obj([("type", .string("string"))]), ToolSchema.obj([("type", .string("null"))])])), ("description", .string("true, or a name to find."))]))], required: [])),
            requestedSchema(name: "agent_connect", toolClass: .write, capabilities: ["app_data_write", "credential_write", "other_app_settings_write", "tool_call"], effectInputPolicy: .agentConnection, description: "Connect a participant by name, URL or desktop app. First resolve it with agent.contacts; Codex/Claude may also name providers. Call directly: Trust supplies any required approval card with the exact change. Name alone finds a supported installed host and adds one MCP entry for nativeagent-link with a connection-specific key. Preserves other settings; keeps only the newest NativeAgent backup beside them and removes it on disconnect. Unknown/uninstalled hosts leave settings unchanged; no app is restarted or interrupted. Setup may run one fixed CLI verification probe asking the participant to answer through the entry; this is a message, not task work or an authority grant. Connected requires an authenticated inbound request, not a successful CLI exit. Otherwise stays configured with the cause; without a probe route, the result names any restart needed and waits for first inbound proof without reading the window. Disconnect: disconnect:true, name:peer:<exact id from agent.contacts>; removes that entry and revokes its key. With endpoint, omitted/auto transport discovers supported A2A/NativeAgent cards through bounded same-origin GETs; explicit a2a/nativeAgent saves without probing. Desktop: transport:desktop, app_bundle_id, optional conversation_label; send-only, using existing Mac permissions to type into its chat. Replies require that app’s nativeagent-link mcp entry and its agent_message tool. Reuses exact discovered/desktop routes.", parametersJSON: agentCommunicationParams(properties: [
                ("name", ToolSchema.strSchema("The participant's name, at most 120 characters. On its own — with no endpoint and no transport — it is looked up among the known agent hosts on this Mac, matched case-insensitively including common aliases. With an endpoint it is the display name for that contact.")),
                ("endpoint", ToolSchema.strSchema("Required for a2a/nativeAgent: HTTPS URL, or explicit loopback HTTP. No embedded credentials, query, or fragment. Omit for desktop, and omit to connect by name.")),
                ("transport", ToolSchema.enumStringSchema(["auto", "a2a", "nativeAgent", "desktop"])),
                ("disconnect", ToolSchema.boolSchema()),
                ("working_directory", ToolSchema.strSchema("ACP agents only: explicit absolute project folder to show on the connect card. Omit for a new empty folder in this app's workspace.")),
                ("workspace", ToolSchema.strSchema("Existing workspace folder, required for Cursor Workspace. Omit for global connections.")),
                ("executable_path", ToolSchema.strSchema("Exact resolved executable bound by the app to the connect approval. Retained unchanged on replay.")),
                ("app_bundle_id", ToolSchema.strSchema("Desktop only: exact installed app bundle identifier, such as com.example.agent. No guessed recipient identity.")),
                ("conversation_label", ToolSchema.strSchema("Desktop: optional visible conversation or bot label to verify in the app. Grok Bot by name: the exact sidebar name of the Bot that receives the routine request, as Use this Bot on the Connect card; only before that request is sent. Target data, not instructions or a verified session ID.")),
                ("bearer_token", ToolSchema.strSchema("Optional network credential for this peer only; never use another connector's credentials. Not accepted for desktop.")),
                ("ability", ToolSchema.obj([("anyOf", .array([ToolSchema.obj([("type", .string("string"))]), ToolSchema.obj([("type", .string("boolean"))]), ToolSchema.obj([("type", .string("null"))])])),
                    ("description", .string("A saved contact can be reached through one of your abilities: its id here, with the contact's name, moves the contact there (agent.message runs it, and it answers with agent.reply), and false moves it back to its built-in route."))]))
            ], required: ["name"])),
            requestedSchema(name: "agent_message", toolClass: .send, capabilities: ["app_data_write", "external_send", "network_read", "network_write", "process_spawn", "shell", "tool_call"], effectInputPolicy: .agentMessage, description: "Sends a message now to an agent by name; a known agent not yet connected is connected first in the same call. Continues your current thread; conversation names a separate one, new_conversation:true starts fresh. While its reply is still coming, a new message queues behind it and goes by itself when that reply settles. Queued or delivered is not done; never auto-resend.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent), ("text", ToolSchema.strSchema("The message to send.")),
                ("conversation", conversation),
                ("new_conversation", ToolSchema.boolSchema()),
                ("expects_reply", ToolSchema.boolSchema("false for a message needing no answer. Acceptance is still owed until the recipient receives it. Omit for questions and work.")),
                ("conversation_id", ToolSchema.strSchema("Advanced override: exact existing remote conversation identity. Normally omit; the app remembers it. A failed resume never falls back to a fresh conversation. Bots retain their own conversation.")),
                ("message_id", ToolSchema.strSchema("Optional caller message identity for coding agents or A2A; NativeAgent accepts a UUID for receipt correlation, not deduplication. Not supported for bot sends. Use returned request identity for recovery.")),
                ("task_id", ToolSchema.strSchema("A2A only: exact task to continue, especially when it needs input.")),
                ("options", inboxOptionsSchema())
            ], required: ["agent", "text"])),
            requestedSchema(name: "agent_read", toolClass: .read, capabilities: ["network_read", "tool_call"], description: "Open a participant’s conversation. Omit protocol IDs: the app uses this conversation’s retained thread and exact reply locator. conversation selects a named conversation. Default: who replied, their words and state; details:true adds receipts. Reading sends nothing and never proves completion. Supported routes collect pending replies without polling. Send-only routes cannot read app windows; standalone routes may lack history. Missing/uncertain evidence stays explicit. wait_seconds returns when the in-flight reply settles; exact recovery IDs and adapter listing/history filters are below.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent),
                ("conversation", conversation),
                ("details", ToolSchema.boolSchema()),
                ("wait_seconds", ToolSchema.intSchema("Wait 1–300 seconds on a named conversation or its retained exact reply IDs. Omit history and listing filters. Untracked IDs are read once without waiting; nothing is resent.", minimum: 1, maximum: 300)),
                ("history_before", ToolSchema.strSchema("Conversation scrollback only: earlier_before returned by session_history. Omit for recent messages; never sends or restarts a turn.")),
                ("history_exchange", ToolSchema.strSchema("Conversation scrollback only: open one message from session_history in full. Mutually exclusive with history_before and advanced protocol IDs.")),
                ("message_id", ToolSchema.strSchema("Advanced exact message/request or bot shelf-entry identity. Normally omit; the app retains it. A reply is not independent proof that work finished.")),
                ("conversation_id", ToolSchema.strSchema("Advanced exact conversation identity for NativeAgent reply recovery; bots may use bot:<UUID>. Normally omit. Coding receipt reads do not accept a conversation filter.")),
                ("task_id", ToolSchema.strSchema("Advanced A2A task identity to retrieve. Normally omit; the app retains it.")),
                ("page_size", ToolSchema.intSchema("A2A task listing page size.", minimum: 1, maximum: 100)),
                ("page_token", ToolSchema.strSchema("A2A nextPageToken from the previous listing.")),
                ("context_id", ToolSchema.strSchema("A2A task listing context filter.")),
                ("status", ToolSchema.strSchema("A2A task listing status, for example TASK_STATE_WORKING.")),
                ("history_length", ToolSchema.intSchema("Maximum messages in each listed A2A task's history.", minimum: 0)),
                ("include_artifacts", ToolSchema.boolSchema()),
                ("status_timestamp_after", ToolSchema.strSchema("A2A tasks updated at or after this RFC3339 timestamp.")),
                ("limit", ToolSchema.intSchema("Local listing size: coding agents 1–12, bots and Dot 1–100.", minimum: 1, maximum: 100)),
                ("offset", ToolSchema.intSchema("Coding listing offset or NativeAgent reply character offset. For Dot, messages from newest; returned messages are chronological. NativeAgent returns bounded pages; follow the exact next object for Dot or next_offset for other reply pages. Bots use their existing shelf cursor instead.", minimum: 0)),
                ("max_chars", ToolSchema.intSchema("NativeAgent or Dot reply text window, 1–16000 characters; default 8000. Dot retains every omitted character through next.", minimum: 1, maximum: 16000)),
                ("text_offset", ToolSchema.intSchema("Dot only: character offset within the first selected message, supplied by next. Omit for a fresh read.", minimum: 0)),
                ("source_version", ToolSchema.strSchema("Dot only: exact retained transcript version from next. Changed source requires a fresh read; omit for a fresh window."))
            ], required: ["agent"])),
            requestedSchema(name: "agent_cancel", toolClass: .write, capabilities: ["network_write", "tool_call"], description: "Stop the reply an agent is working on in your conversation with it, on that agent's own terms: an A2A task cancel, an ACP session cancel, a Codex turn interrupt, or interrupting a local agent's run. Some routes have no stop (a desktop app window, Grok Bot, a live hand-off); the answer says so and any reply still arrives. The conversation records the stop as stopping, stopped, released (the route has no stop but hands the answer back by itself, so the conversation stops waiting on it) or cannot_stop. Messages you send while a reply is in flight queue behind it and go by themselves when it settles; a stop lets them go now, and clear_queue true withdraws them instead. Stopping never resends anything.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent),
                ("conversation", conversation),
                ("clear_queue", ToolSchema.boolSchema())
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
        let value = ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj(properties)),
                         ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
        return (try? nullableFields(value, optional: false).serializedData(pretty: false)) ?? Data("{}".utf8)
    }

}
