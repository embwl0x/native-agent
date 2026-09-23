import Foundation
import NativeAgentCore
import PersistenceCore

extension BuiltInToolSchemaFactory {
    func standingBotSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["bot_create", "bot_update", "bot_pause", "bot_delete", "bot_list", "bot_run_once", "bot_ask", "shelf_read", "shelf_entry"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        func optional(_ schema: JSONValue) -> JSONValue {
            if case .object(let fields) = schema, fields["type"] != nil {
                return nullableRecallField(schema)
            }
            return obj([("anyOf", .array([schema, obj([("type", .string("null"))])]))])
        }
        func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
            obj([("type", .string("object")), ("properties", obj(properties.map {
                ($0.0, required.contains($0.0) ? $0.1 : optional($0.1))
            })),
                 ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
        }
        let fields: [(String, JSONValue)] = [
            ("name", strSchema("Name chosen for this bot.")),
            ("brief", strSchema("What the bot should do, in the agent's words.")),
            ("output_format", strSchema("Desired output, in the agent's words. Empty means no requested form.")),
            ("provider", strSchema("Connected provider ID. bot_list with include_models true shows configured accounts, model IDs and supported Think choices. Required when making a bot: a bot runs on the route it was made with.")),
            ("model", strSchema("Model this bot runs on. Required when making a bot — pick one the chosen provider serves. A bot does not follow Chat's model.")),
            ("reasoning_effort", strSchema("Think level for this bot. Required when making a bot; must be one the chosen model supports.")),
            ("fast", nullableRecallField(boolSchema())),
            ("schedule", strSchema("Simple timing: manual, every 30 minutes, every 2 hours, daily at 09:00, weekdays at 09:00, or weekly on monday at 09:00. Use 24-hour HH:mm. Supply schedule OR legacy cadence, never both. Other prose is refused rather than guessed.")),
            ("timezone", strSchema("Optional IANA time zone for a daily, weekday or weekly schedule, such as America/Denver. Omit to persist this Mac's current zone. Do not supply for manual/interval or alongside legacy cadence; cron already has timeZone.")),
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
        // Agent, 2026-09-14: three bot_ask calls were spent discovering that
        // `id` was the only accepted spelling — the compact catalog row carries
        // the description, not the parameters, so the description has to say
        // the shape. Dispatch accepts all four spellings and one bot name.
        let id = strSchema("Which bot: its ID from bot_list, or its name. Also accepted as bot_id, bot or name.")
        let botReference: [(String, JSONValue)] = [
            ("id", id), ("bot_id", id), ("bot", id), ("name", id),
        ].map { ($0.0, optional($0.1)) }
        let details = ("details", optional(boolSchema()))
        let createRequired = ["name", "brief", "provider", "model", "reasoning_effort"]
        return [
            // User, 2026-09-13: "Bots has no default model; Agent is supposed to
            // pick the model when she makes one." A bot's route and model are
            // part of its definition, not an inheritance from Chat.
            requestedSchema(name: "bot_create", description: "Make a standing helper with its own persistent chat. Choose name, brief, provider, model and reasoning_effort explicitly: no model inherits from Chat. Optional schedule accepts simple timing such as every 30 minutes or weekdays at 09:00; omitted timing is manual. Creation saves the helper; it does not run it. The result gives its job, model, resolved timing and actions. details true includes all settings.", parametersJSON: params(properties: fields.map { ($0.0, createRequired.contains($0.0) ? $0.1 : optional($0.1)) } + [details], required: createRequired)),
            requestedSchema(name: "bot_update", description: "Change a helper by name and keep its session and saved replies. Pass fields with only settings to change; unused null fields are ignored. schedule accepts simple timing. Model changes remain explicit and must form a valid provider/model/reasoning_effort choice. details true includes all saved settings.", parametersJSON: params(properties: botReference + [("fields", object(fields, required: [])), details], required: ["fields"])),
            requestedSchema(name: "bot_pause", description: "Pause or resume a helper's scheduled turns by name and paused (true or false). This does not cancel an in-flight run. Manual follow-ups and run once still work; resuming keeps the same context and saved replies. details true includes all settings.", parametersJSON: params(properties: botReference + [("paused", boolSchema()), details], required: ["paused"])),
            requestedSchema(name: "bot_delete", description: "Remove a bot from the active list and stop its schedule. Keep its session and saved replies. Name the bot by id, bot_id, bot or name.", parametersJSON: params(properties: botReference, required: [])),
            requestedSchema(name: "bot_list", description: "See helpers by name, job, chosen model, resolved schedule and status. Optional id opens one exact helper. include_models true also shows configured provider accounts with model IDs and supported Think levels, for choosing a helper model without searching settings or introspecting Chat. It does not change any choice or test a service. details true includes full bot settings.", parametersJSON: params(properties: [details, ("id", optional(id)), ("include_models", optional(boolSchema()))], required: [])),
            requestedSchema(name: "bot_run_once", description: "Queue the helper's standing job once, including while paused. Name it by id, bot_id, bot or name. When the result says automatic_return true, the app waits and brings the outcome to this initiating conversation; do not poll or resend. The dated reply is also saved on the shelf. Raw calls outside a chat use the shelf to read their result.", parametersJSON: params(properties: botReference, required: [])),
            requestedSchema(name: "bot_ask", description: "Talk to a helper in its existing chat session by name and question. Its current standing brief accompanies every turn; your question does not change that standing job. Returns the reply under current Trust and the helper's chosen model and limits.", parametersJSON: params(properties: botReference.map { ($0.0, nullableRecallField($0.1)) } + [("question", strSchema("Follow-up message."))], required: ["question"])),
            requestedSchema(name: "shelf_read", description: "Read a compact index of saved replies. Defaults to unread replies and marks only returned entries read. Use include_read true to browse history, including previously read answers, without changing unread state. Every argument is optional: name one bot by id, bot_id, bot or name, and narrow with since, topic, limit and cursor. Use newest_first true to start with recent saved replies; the default is oldest first. Follow nextCursor with the same filters, including include_read and newest_first.", parametersJSON: params(properties: [
                ("id", nullableRecallField(id)), ("bot_id", nullableRecallField(id)), ("bot", nullableRecallField(id)), ("name", nullableRecallField(id)),
                ("since", nullableRecallField(strSchema("Exclusive ISO 8601 date."))),
                ("topic", nullableRecallField(strSchema("Text to find in replies."))),
                ("limit", nullableRecallField(intSchema(minimum: 1, maximum: 100))),
                ("include_read", optional(boolSchema())),
                ("newest_first", optional(boolSchema())),
                ("cursor", nullableRecallField(strSchema("nextCursor from the previous page.")))
            ], required: [])),
            requestedSchema(name: "shelf_entry", description: "Open a helper's latest settled reply by bot or name, including its full answer, artifacts and actual run status. Or pass id for one exact saved reply; optional bot_id verifies its owner. Marks only the returned entry read, including when it was already read before.", parametersJSON: params(properties: [("id", optional(strSchema("Exact shelf entry UUID; omit to read the latest reply for a named bot."))), ("bot_id", optional(strSchema("Bot name or UUID when selecting its latest reply; with id, the expected bot UUID."))), ("bot", optional(id)), ("name", optional(id))], required: []))
        ]
    }
}
