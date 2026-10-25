import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |

extension BuiltInToolSchemaFactory {
    func standingBotSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["bot_create", "bot_update", "bot_pause", "bot_delete", "bot_list", "bot_run_once", "bot_ask", "shelf_read", "shelf_entry"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        func optional(_ schema: JSONValue) -> JSONValue {
            if case .object(let fields) = schema, fields["type"] != nil {
                return nullableRecallField(schema)
            }
            return ToolSchema.obj([("anyOf", .array([schema, ToolSchema.obj([("type", .string("null"))])]))])
        }
        func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
            ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj(properties.map {
                ($0.0, required.contains($0.0) ? $0.1 : optional($0.1))
            })),
                 ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
        }
        var eventTrigger = object([
            ("source", ToolSchema.enumStringSchema(["slack"], "slack: a message in a channel the Slack connector receives.")),
            ("filter", ToolSchema.strSchema("The Slack channel ID such as C0123ABCD. Slack delivers IDs, never names.")),
            ("keyword", ToolSchema.strSchema("Optional word the event text must contain.")),
        ], required: ["source", "filter"])
        if case .object(var trigger) = eventTrigger {
            trigger["description"] = .string("Wake the helper on an outside event, as On an event does in the Bots editor. The event replaces the schedule: the helper keeps no timing of its own. Any later schedule or cadence change removes the trigger. Autonomy off holds an event instead of running it.")
            eventTrigger = .object(trigger)
        }
        let fields: [(String, JSONValue)] = [
            ("name", ToolSchema.strSchema("Name chosen for this bot.")),
            ("personality", ToolSchema.strSchema("Who this helper is: its own personality, voice and character, in your words. It is its own someone, never you. Omit for a helper defined by its job alone.")),
            ("brief", ToolSchema.strSchema("What the bot should do, in the agent's words.")),
            ("output_format", ToolSchema.strSchema("Desired output, in the agent's words. Empty means no requested form.")),
            ("provider", ToolSchema.strSchema("Connected provider ID for a pinned model. bot.list include_models true shows accounts and model choices. Omit provider, model and reasoning_effort to follow Providers for Chat.")),
            ("model", ToolSchema.strSchema("An explicit model choice pins this helper to that model. Supply its provider and supported reasoning_effort. Omit to follow Providers for Chat.")),
            ("model_pinned", ToolSchema.boolSchema("False follows Providers for Chat and clears the saved provider/model/Think/Fast choice. True pins the supplied choice. Creation defaults to following Providers unless model is explicitly supplied.")),
            ("reasoning_effort", ToolSchema.strSchema("Supported Think level for a pinned model. Followers use Providers for Chat's Think level.")),
            ("fast", nullableRecallField(ToolSchema.boolSchema())),
            ("schedule", ToolSchema.strSchema("Simple timing: manual, every 30 minutes, every 2 hours, daily at 09:00, weekdays at 09:00, or weekly on monday at 09:00. Use 24-hour HH:mm on this Mac's local clock; times follow the Mac when it changes zone. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Supply schedule OR cadence, never both. Other prose is refused rather than guessed. Example: \"every 30 minutes\".")),
            ("cadence", ToolSchema.obj([("description", .string(
                "Advanced timing object; prefer schedule for simple timing. Supply exactly one non-null manual, interval or cron branch, never alongside schedule. Interval seconds must meet Minimum cadence on the Bots page (60–900 seconds; default 900). cron requires expression, read on this Mac's local clock. Example: {\"manual\":{}}."
            )), ("oneOf", .array([
                object([("manual", object([], required: []))], required: ["manual"]),
                object([("interval", object([("seconds", numSchema(minimum: standingBotMinimumInterval))], required: ["seconds"]))], required: ["interval"]),
                object([("cron", object([("expression", ToolSchema.strSchema())], required: ["expression"]))], required: ["cron"])
            ]))])),
            ("budget", object([("tokens", ToolSchema.intSchema("Whole-turn output token allowance; measured conservatively across requests.", minimum: 1)),
                ("seconds", ToolSchema.intSchema("Maximum run duration.", minimum: 1))], required: ["tokens", "seconds"])),
            ("daily_token_ceiling", ToolSchema.intSchema("Daily allowance for this bot. Each run reserves its full token limit.", minimum: 1)),
            // User, 2026-10-01: the Bots editor's "On an event" and "Tell me if",
            // so the agent can set everything the editor sets.
            ("event_trigger", eventTrigger),
            ("notify_condition", ToolSchema.strSchema("The Bots editor's Tell me if: after each scheduled, event or run-once run, the helper judges its own result against this condition and the person is notified only when it is met. An empty string clears it.")),
        ]
        // Agent, 2026-09-14: three bot_ask calls were spent discovering that
        // `id` was the only accepted spelling — the compact catalog row carries
        // the description, not the parameters, so the description has to say
        // the shape. Dispatch accepts all four spellings and one bot name.
        let id = ToolSchema.strSchema("Which bot: its ID from bot.list, or its name. Also accepted as bot_id, bot or name.")
        let botReference: [(String, JSONValue)] = [
            ("id", id), ("bot_id", id), ("bot", id), ("name", id),
        ].map { ($0.0, optional($0.1)) }
        let details = ("details", optional(ToolSchema.boolSchema()))
        let createRequired = ["name", "brief"]
        return [
            requestedSchema(name: "bot_create", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Make a standing helper with its own persistent conversation. Required: name and brief. It follows Providers for Chat unless an explicit provider/model/reasoning_effort choice pins it. bot.list include_models true shows connected choices. Optional schedule accepts simple timing; omitted timing is manual. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Creation saves the helper; it does not run it. Set paused true to pause scheduled turns from creation. details true includes all settings. Example: {\"name\":\"Research helper\",\"brief\":\"Summarize research when asked.\",\"schedule\":\"manual\"}.", parametersJSON: ToolSchema.params(properties: fields.map { ($0.0, createRequired.contains($0.0) ? $0.1 : optional($0.1)) } + [("paused", optional(ToolSchema.boolSchema("Start with scheduled turns paused. Default false. Manual messages and run once remain available."))), details], required: createRequired)),
            requestedSchema(name: "bot_update", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Change a helper and keep its conversation and saved replies. Required: a bot reference (id, bot_id, bot or name) and fields with at least one changed setting; unused null fields are ignored. schedule accepts simple timing; intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Model changes must form a valid provider/model/reasoning_effort choice. details true includes all saved settings. Example for an existing helper: {\"name\":\"Research helper\",\"fields\":{\"schedule\":\"manual\"}}.", parametersJSON: ToolSchema.params(properties: botReference + [("fields", object(fields, required: [])), details], required: ["fields"])),
            requestedSchema(name: "bot_pause", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Pause or resume a helper's scheduled turns by name and paused (true or false). This does not cancel an in-flight run. Manual follow-ups and run once still work; resuming keeps the same context and saved replies. details true includes all settings.", parametersJSON: ToolSchema.params(properties: botReference + [("paused", ToolSchema.boolSchema()), details], required: ["paused"])),
            requestedSchema(name: "bot_delete", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Delete a bot's definition and audit and stop its schedule. Keep its conversation and saved replies. Name the bot by id, bot_id, bot or name.", parametersJSON: ToolSchema.params(properties: botReference, required: [])),
            requestedSchema(name: "bot_list", toolClass: .read, capabilities: ["external_send", "notification", "safe_read", "tool_call"], description: "See helpers by name, job, chosen model, resolved schedule and status. Optional id opens one exact helper. include_models true also shows configured provider accounts with model IDs and supported Think levels, for choosing a helper model without searching settings or introspecting Chat. It does not change any choice or test a service. details true includes full bot settings.", parametersJSON: ToolSchema.params(properties: [details, ("id", optional(id)), ("include_models", optional(ToolSchema.boolSchema()))], required: [])),
            requestedSchema(name: "bot_run_once", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Queue the helper's standing job once, including while paused. Name it by id, bot_id, bot or name. Optional question gives this run its input without changing the standing job. When the result says automatic_return true, the app waits and brings the outcome to this initiating conversation; do not poll or resend. The dated reply is also saved on the shelf. Raw calls outside a chat use the shelf to read their result.", parametersJSON: ToolSchema.params(properties: botReference + [("question", optional(ToolSchema.strSchema("Question or context for this run only.")))], required: [])),
            requestedSchema(name: "bot_ask", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Talk to a helper in its existing conversation by name and question. Its current standing brief accompanies every turn; your question does not change that standing job. Returns the reply under current Trust and the helper's chosen model and limits.", parametersJSON: ToolSchema.params(properties: botReference.map { ($0.0, nullableRecallField($0.1)) } + [("question", ToolSchema.strSchema("Follow-up message."))], required: ["question"])),
            requestedSchema(name: "shelf_read", toolClass: .read, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Read a compact index of saved replies. Defaults to unread replies without changing unread state. Use include_read true to browse history, including previously read answers. Only mark_read true marks returned entries read. Every argument is optional: name one bot by id, bot_id, bot or name, and narrow with since, topic, limit and cursor. Use newest_first true to start with recent saved replies; the default is oldest first. Follow nextCursor with the same filters, including include_read and newest_first.", parametersJSON: ToolSchema.params(properties: [
                ("id", nullableRecallField(id)), ("bot_id", nullableRecallField(id)), ("bot", nullableRecallField(id)), ("name", nullableRecallField(id)),
                ("since", nullableRecallField(ToolSchema.strSchema("Exclusive start: YYYY-MM-DD (local day) or ISO 8601 time with time zone."))),
                ("topic", nullableRecallField(ToolSchema.strSchema("Text to find in replies."))),
                ("limit", nullableRecallField(ToolSchema.intSchema(minimum: 1, maximum: 100))),
                ("include_read", optional(ToolSchema.boolSchema())),
                ("mark_read", optional(ToolSchema.boolSchema("Mark only returned entries read. Default false."))),
                ("newest_first", optional(ToolSchema.boolSchema())),
                ("cursor", nullableRecallField(ToolSchema.strSchema("nextCursor from the previous page.")))
            ], required: [])),
            requestedSchema(name: "shelf_entry", toolClass: .read, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Open a helper's latest settled reply by bot or name, including its full answer, artifacts and actual run status. Or pass id for one exact saved reply; optional bot_id verifies its owner. Marks only the returned entry read by default; mark_read false leaves unread state unchanged. save_to a folder also saves the reply's attached files there.", parametersJSON: ToolSchema.params(properties: [("id", optional(ToolSchema.strSchema("Exact shelf entry UUID; omit to read the latest reply for a named bot."))), ("bot_id", optional(ToolSchema.strSchema("Bot name or UUID when selecting its latest reply; with id, the expected bot UUID."))), ("bot", optional(id)), ("name", optional(id)), ("mark_read", optional(ToolSchema.boolSchema("Mark the returned entry read. Default true; false reads without acknowledgement."))), ("save_to", optional(ToolSchema.strSchema("Folder to save the reply's attached files into, as Save does on the Helpers shelf. Each file keeps its own name; a file already there is never replaced. A folder outside the trusted workspace asks the person for file access.")))], required: []))
        ]
    }
}
