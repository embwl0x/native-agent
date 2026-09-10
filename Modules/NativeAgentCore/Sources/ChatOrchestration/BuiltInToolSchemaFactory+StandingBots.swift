import Foundation
import NativeAgentCore
import PersistenceCore

extension BuiltInToolSchemaFactory {
    func standingBotSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["bot_create", "bot_update", "bot_pause", "bot_delete", "bot_list", "bot_run_once", "bot_ask", "shelf_read", "shelf_entry"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
            obj([("type", .string("object")), ("properties", obj(properties)),
                 ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
        }
        let fields: [(String, JSONValue)] = [
            ("name", strSchema("Name chosen for this bot.")),
            ("brief", strSchema("What the bot should do, in the agent's words.")),
            ("output_format", strSchema("Desired output, in the agent's words. Empty means no requested form.")),
            ("provider", strSchema("Connected provider ID from Providers. Omit to use the same route as Chat.")),
            ("model", strSchema("Model chosen for this bot. Omit to use the same model as Chat.")),
            ("reasoning_effort", strSchema("Think level chosen for this bot. Omit to use Chat's.")),
            ("fast", boolSchema()),
            ("cadence", obj([("oneOf", .array([
                object([("manual", object([], required: []))], required: ["manual"]),
                object([("interval", object([("seconds", intSchema(minimum: 60))], required: ["seconds"]))], required: ["interval"]),
                object([("cron", object([("expression", strSchema()), ("timeZone", strSchema())], required: ["expression", "timeZone"]))], required: ["cron"])
            ]))])),
            ("budget", object([("tokens", intSchema("Whole-turn output token allowance; measured conservatively across requests.", minimum: 1)),
                ("seconds", intSchema("Maximum run duration.", minimum: 1))], required: ["tokens", "seconds"])),
            ("daily_token_ceiling", intSchema("Daily allowance for this bot. Each run reserves its full token limit.", minimum: 1)),
        ]
        let id = strSchema("Bot ID from bot_list or bot_create.")
        return [
            requestedSchema(name: "bot_create", description: "Make a standing helper: a persistent sub-agent with its own chat session, the same tools and Trust as you, that keeps its context until deleted. Only name and brief are required; anything omitted means the same as Chat, manual timing, and the default limits.", parametersJSON: params(properties: fields, required: ["name", "brief"])),
            requestedSchema(name: "bot_update", description: "Change selected bot settings and keep the same session and saved replies.", parametersJSON: params(properties: [("id", id), ("fields", object(fields, required: []))], required: ["id", "fields"])),
            requestedSchema(name: "bot_pause", description: "Pause or resume scheduled turns. Follow-ups and run once remain available.", parametersJSON: params(properties: [("id", id), ("paused", boolSchema())], required: ["id", "paused"])),
            requestedSchema(name: "bot_delete", description: "Remove a bot from the active list and stop its schedule. Keep its session and saved replies.", parametersJSON: params(properties: [("id", id)], required: ["id"])),
            requestedSchema(name: "bot_list", description: "List bots with their model choices, timing, limits and session IDs. Sessions open in Chat.", parametersJSON: params(properties: [], required: [])),
            requestedSchema(name: "bot_run_once", description: "Queue one turn, including while paused. The dated reply appears on the shelf.", parametersJSON: params(properties: [("id", id)], required: ["id"])),
            requestedSchema(name: "bot_ask", description: "Send a follow-up into the bot's same chat session and return the reply. Uses current Trust and approvals and the bot's limits.", parametersJSON: params(properties: [("id", id), ("question", strSchema("Follow-up message."))], required: ["id", "question"])),
            requestedSchema(name: "shelf_read", description: "Read a compact index of saved replies. Only returned entries are marked read; follow nextCursor with the same filters.", parametersJSON: params(properties: [
                ("bot", nullableRecallField(id)), ("since", nullableRecallField(strSchema("Exclusive ISO 8601 date."))),
                ("topic", nullableRecallField(strSchema("Text to find in replies."))),
                ("limit", nullableRecallField(intSchema(minimum: 1, maximum: 100))),
                ("cursor", nullableRecallField(strSchema("nextCursor from the previous page.")))
            ], required: [])),
            requestedSchema(name: "shelf_entry", description: "Read the exact dated reply, artifacts, session ID and run status. Mark only this entry read.", parametersJSON: params(properties: [("id", strSchema("Shelf entry ID."))], required: ["id"]))
        ]
    }
}
