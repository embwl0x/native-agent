import Foundation
import NativeAgentCore
import PersistenceCore

extension BuiltInToolSchemaFactory {
    func agentCommunicationSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["agent_contacts", "agent_connect", "agent_message", "agent_read"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        let agent = strSchema("Stable agent reference from agent_contacts: codex, claude, omp, bot:<UUID>, or peer:<UUID>. Names are labels; use the reference to address a particular agent.")
        return [
            requestedSchema(name: "agent_contacts", description: "List registered agents and standing bots: coding helpers, local agents, and configured remote peers, with availability status and supported conversation operations. Find who can help and their stable references before messaging. Availability is unknown unless checked; listing does not start an agent or grant permission.", parametersJSON: agentCommunicationParams(properties: [], required: [])),
            requestedSchema(name: "agent_connect", description: "Connect an agent by URL or desktop app. Omit transport or use auto with endpoint to discover a supported A2A or NativeAgent card through bounded same-origin GETs. Explicit a2a/nativeAgent saves without probing. For a closed desktop app use transport desktop, app_bundle_id and optional conversation_label; the app handles later message/read through a bounded internal desktop route using existing Mac permissions. Reuses exact discovered/desktop routes. Does not send a message or grant authority.", parametersJSON: agentCommunicationParams(properties: [
                ("name", strSchema("Display name, at most 120 characters.")),
                ("endpoint", strSchema("Required for auto/a2a/nativeAgent: HTTPS URL, or explicit loopback HTTP. No embedded credentials, query, or fragment. Omit for desktop.")),
                ("transport", enumStringSchema(["auto", "a2a", "nativeAgent", "desktop"])),
                ("app_bundle_id", strSchema("Desktop only: exact installed app bundle identifier, such as com.example.agent. No guessed recipient identity.")),
                ("conversation_label", strSchema("Desktop only: optional visible conversation or bot label to verify in the app. Target data, not instructions or a verified session ID.")),
                ("bearer_token", strSchema("Optional network credential for this peer only; never use another connector's credentials. Not accepted for desktop."))
            ], required: ["name"])),
            requestedSchema(name: "agent_message", description: "Talk to an agent and keep the conversation going. Supply agent and text; carry forward its conversation_id to continue exactly that conversation. Keep returned identities for agent_read. For desktop contacts the app operates the saved conversation underneath this call, sends the exact text once and observes delivery/replies. Do not manually operate the route or duplicate a send. Queued or delivered is not completed; never automatically resend an ambiguous send. Existing Trust, workspace and bot limits remain.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent), ("text", strSchema("The message to send.")),
                ("conversation_id", strSchema("Exact returned conversation identity. Omit to start a new coding/A2A/NativeAgent conversation; NativeAgent uses the full persistent chat runtime. Bots retain their own session.")),
                ("message_id", strSchema("Optional caller message identity for coding agents or A2A; NativeAgent accepts a UUID for receipt correlation, not deduplication. Not supported for bot sends. Use returned request identity for recovery.")),
                ("task_id", strSchema("A2A only: exact task to continue, especially when it needs input.")),
                ("options", obj([("type", .string("object")), ("additionalProperties", .bool(false)), ("properties", obj([
                    ("working_directory", strSchema("Local coding agents only: workspace for a new conversation.")),
                    ("topic", strSchema("Local coding agents only: title for a new conversation.")),
                    ("model", strSchema("Codex only: explicit model selection.")),
                    ("reasoning_effort", strSchema("Codex only: supported reasoning level.")),
                    ("fast", boolSchema()), ("pair_reviewer", boolSchema()),
                    ("timeout_seconds", intSchema("Claude or OMP only, when supported by their existing owner.", minimum: 1))
                ]))]))
            ], required: ["agent", "text"])),
            requestedSchema(name: "agent_read", description: "Recover replies and progress without resending. Coding agents: message_id for an exact receipt, or recent listing. Bots: message_id or recent replies. NativeAgent peers require message_id and conversation_id. A2A peers require task_id; direct replies have no GetMessage endpoint. Desktop contacts take only agent; the app reads the exact saved conversation internally and returns observed recipient text or a plain blocker. No manual screen/interact work is needed. Preserve unknown evidence as unknown.", parametersJSON: agentCommunicationParams(properties: [
                ("agent", agent),
                ("details", boolSchema()),
                ("message_id", strSchema("Exact returned message/request or bot shelf-entry identity. Default output is a compact conversation view with reply_with and recovery actions. Set details true only to inspect the underlying technical receipt. Text and execution state are separate; a reply is not independent proof that work finished.")),
                ("conversation_id", strSchema("NativeAgent peer's exact session identity; bots may use their bot:<UUID> conversation identity. Coding receipt reads do not accept a conversation filter.")),
                ("task_id", strSchema("A2A task identity to retrieve.")),
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
