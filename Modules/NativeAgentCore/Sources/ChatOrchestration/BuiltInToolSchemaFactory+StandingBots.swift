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
            ("provider", strSchema("Connected provider ID from Providers. Required when making a bot: a bot runs on the route it was made with.")),
            ("model", strSchema("Model this bot runs on. Required when making a bot — pick one the chosen provider serves. A bot does not follow Chat's model.")),
            ("reasoning_effort", strSchema("Think level for this bot. Required when making a bot; must be one the chosen model supports.")),
            ("fast", boolSchema()),
            // A model calling this tool from memory, with the schema unloaded,
            // still has to get the shape right: name all three and show each
            // (2026-09-13, the 0.4.12 drive — two bot_create calls raised an
            // approval card and only then failed on cadence shape and floor).
            ("cadence", obj([("description", .string(
                "An object with exactly one of manual, interval or cron — never a bare number or string. "
                + "manual: {\"manual\":{}}. "
                + "interval: {\"interval\":{\"seconds\":3600}} — seconds must be at least the person's Minimum cadence on the Bots page, 15 minutes (900) by default. "
                + "cron: {\"cron\":{\"expression\":\"0 9 * * *\",\"timeZone\":\"America/New_York\"}}."
            )), ("oneOf", .array([
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
            // User, 2026-09-13: "Bots has no default model; Agent is supposed to
            // pick the model when she makes one." A bot's route and model are
            // part of its definition, not an inheritance from Chat.
            requestedSchema(name: "bot_create", description: "Make a standing helper: a persistent sub-agent with its own chat session, the same tools and Trust as you, that keeps its context until deleted. Name, brief, provider, model and reasoning_effort are required — a bot always runs on the model it was made with, never on Chat's. Timing and limits default to manual and the usual allowances.", parametersJSON: params(properties: fields, required: ["name", "brief", "provider", "model", "reasoning_effort"])),
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
