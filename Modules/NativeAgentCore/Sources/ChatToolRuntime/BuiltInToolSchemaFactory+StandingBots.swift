import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |

extension BuiltInToolSchemaFactory {
    func standingBotSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["bot_create", "bot_update", "bot_pause", "bot_delete", "bot_list", "bot_run_once", "bot_ask", "shelf_read", "shelf_entry"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
            ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj(properties.map {
                ($0.0, required.contains($0.0) ? $0.1 : ToolSchema.nullable($0.1))
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
            ("fast", ToolSchema.nullable(ToolSchema.boolSchema())),
            ("schedule", ToolSchema.strSchema("Simple timing: manual, every 30 minutes, every 2 hours, daily at 09:00, weekdays at 09:00, or weekly on monday at 09:00. Use 24-hour HH:mm on this Mac's local clock; times follow the Mac when it changes zone. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Supply schedule OR cadence, never both. Other prose is refused rather than guessed. Example: \"every 30 minutes\".")),
            ("cadence", .object([
                "description": .string("Advanced timing object; prefer schedule for simple timing. Supply exactly one non-null manual, interval or cron branch, never alongside schedule. Interval seconds must meet Minimum cadence on the Bots page (60–900 seconds; default 900). cron requires expression, read on this Mac's local clock. Example: {\"manual\":{}}."),
                "type": .string("object"), "additionalProperties": .bool(false), "minProperties": .int(1), "maxProperties": .int(1),
                "properties": ToolSchema.obj([("manual", object([], required: [])),
                    ("interval", object([("seconds", numSchema(minimum: standingBotMinimumInterval))], required: ["seconds"])),
                    ("cron", object([("expression", ToolSchema.strSchema())], required: ["expression"]))])
            ])),
            ("budget", object([("tokens", ToolSchema.intSchema("Whole-turn output token allowance; measured conservatively across requests.", minimum: 1)),
                ("seconds", ToolSchema.obj([("type", .string("number")), ("exclusiveMinimum", .int(0)), ("description", .string("Maximum run duration."))]))], required: ["tokens", "seconds"])),
            ("daily_token_ceiling", ToolSchema.intSchema("Daily allowance for this bot. Each run reserves its full token limit.", minimum: 1)),
            // Bot tools expose the editor's event trigger and notification condition.
            ("event_trigger", eventTrigger),
            ("notify_condition", ToolSchema.strSchema("The Bots editor's Tell me if: after each scheduled, event or run-once run, the helper judges its own result against this condition and the person is notified only when it is met. An empty string clears it.")),
        ]
        // One public reference across listing, running and managing helpers.
        // Old spellings remain accepted by dispatch for saved internal calls.
        let id = ToolSchema.strSchema("Which helper: id is its UUID from bot.list, or its exact name.")
        let botReference: [(String, JSONValue)] = [("id", id)]
        let details = ("details", ToolSchema.nullable(ToolSchema.boolSchema()))
        let createRequired = ["name", "brief"]
        return [
            requestedSchema(name: "bot_create", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Make a standing helper with its own persistent conversation. Required: name and brief. It follows Providers for Chat unless an explicit provider/model/reasoning_effort choice pins it. bot.list include_models true shows connected choices. Optional schedule accepts simple timing; omitted timing is manual. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Creation saves the helper; it does not run it. Set paused true to pause scheduled turns from creation. details true includes all settings. Example: {\"name\":\"Research helper\",\"brief\":\"Summarize research when asked.\",\"schedule\":\"manual\"}.", parametersJSON: (try! object(fields.map { ($0.0, createRequired.contains($0.0) ? $0.1 : ToolSchema.nullable($0.1)) } + [("paused", ToolSchema.nullable(ToolSchema.boolSchema("Start with scheduled turns paused. Default false. Manual messages and run once remain available."))), details], required: createRequired).serializedData(pretty: false))),
            requestedSchema(name: "bot_update", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Change a helper and keep its conversation and saved replies. Required: id (helper UUID or exact name) and fields with at least one changed setting; unused null fields are ignored. schedule accepts simple timing; intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Model changes must form a valid provider/model/reasoning_effort choice. details true includes all saved settings. Example for an existing helper: {\"id\":\"Research helper\",\"fields\":{\"schedule\":\"manual\"}}.", parametersJSON: (try! object(botReference + [("fields", object(fields, required: [])), details], required: ["id", "fields"]).serializedData(pretty: false))),
            requestedSchema(name: "bot_pause", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Pause or resume scheduled turns using id and paused (true or false). A helper without a schedule refuses with effects none. This does not cancel an in-flight run. Manual follow-ups and run once still work; resuming keeps the same context and saved replies. details true includes all settings. Example: {\"id\":\"Research helper\",\"paused\":true}.", parametersJSON: (try! object(botReference + [("paused", ToolSchema.boolSchema()), details], required: ["id", "paused"]).serializedData(pretty: false))),
            requestedSchema(name: "bot_delete", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Delete a helper using id (UUID or exact name) and stop future runs. Keep its definition and audit for owned run settlement, conversation and saved replies. Example: {\"id\":\"Research helper\"}.", parametersJSON: (try! object(botReference, required: ["id"]).serializedData(pretty: false))),
            requestedSchema(name: "bot_list", toolClass: .read, capabilities: ["external_send", "notification", "safe_read", "tool_call"], description: "See helpers by name, job, chosen model, resolved schedule and status. Optional id opens one exact helper. include_models true also shows configured provider accounts with model IDs and supported Think levels, for choosing a helper model without searching settings or introspecting Chat. It does not change any choice or test a service. details true includes full bot settings.", parametersJSON: (try! object([details, ("id", ToolSchema.nullable(id)), ("include_models", ToolSchema.nullable(ToolSchema.boolSchema()))], required: []).serializedData(pretty: false))),
            requestedSchema(name: "bot_run_once", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Queue the helper's standing job once using id, including while paused. Optional question gives this run its input without changing the standing job. With automatic_return true, success or failure returns as one line with its bot.reply shelf reference in the initiating conversation, through the peer reply-delivery path; do not poll or resend. Delivery needs no second model turn. Raw calls outside a chat use the shelf. Example: {\"id\":\"Research helper\"}.", parametersJSON: (try! object(botReference + [("question", ToolSchema.nullable(ToolSchema.strSchema("Question or context for this run only.")))], required: ["id"]).serializedData(pretty: false))),
            requestedSchema(name: "bot_ask", toolClass: .write, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Talk to a helper in its existing conversation using id and question. Its current standing brief accompanies every turn; your question does not change that standing job. Returns the reply under current Trust and the helper's chosen model and limits.", parametersJSON: (try! object(botReference.map { ($0.0, ToolSchema.nullable($0.1)) } + [("question", ToolSchema.strSchema("Follow-up message."))], required: ["id", "question"]).serializedData(pretty: false))),
            requestedSchema(name: "shelf_read", toolClass: .read, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Read saved replies newest first by default, including already read replies. sort accepts newest_first, oldest_first or oldest_unread; oldest_unread explicitly selects unread replies oldest first. include_read false selects unread replies in the chosen order. Only mark_read true marks returned entries read. Optional id selects one helper; since and topic narrow results. Page with offset (default 0, follow next_offset) or cursor (follow nextCursor), never both, keeping the same filters and sort. Headlines end at a word.", parametersJSON: (try! object([
                ("id", ToolSchema.nullable(id)),
                // Saved calls still pass through the app door's schema validation.
                ("bot_id", ToolSchema.nullable(ToolSchema.strSchema("Legacy saved-call spelling of id; new calls use id."))),
                ("bot", ToolSchema.nullable(ToolSchema.strSchema("Legacy saved-call spelling of id; new calls use id."))),
                ("name", ToolSchema.nullable(ToolSchema.strSchema("Legacy saved-call spelling of id; new calls use id."))),
                ("since", ToolSchema.nullable(ToolSchema.strSchema("Exclusive start: YYYY-MM-DD (local day) or ISO 8601 time with time zone."))),
                ("topic", ToolSchema.nullable(ToolSchema.strSchema("Text to find in replies."))),
                ("limit", ToolSchema.nullable(ToolSchema.intSchema(minimum: 1, maximum: 100))),
                ("include_read", ToolSchema.nullable(ToolSchema.boolSchema())),
                ("mark_read", ToolSchema.nullable(ToolSchema.boolSchema("Mark only returned entries read. Default false."))),
                ("sort", ToolSchema.nullable(ToolSchema.enumStringSchema(["newest_first", "oldest_first", "oldest_unread"], "Default newest_first; oldest_unread selects unread only."))),
                ("newest_first", ToolSchema.nullable(ToolSchema.boolSchema("Legacy saved-call ordering; new calls use sort."))),
                ("offset", ToolSchema.nullable(ToolSchema.intSchema("Zero-based offset in matching replies. Use without cursor.", minimum: 0))),
                ("cursor", ToolSchema.nullable(ToolSchema.strSchema("nextCursor from the previous page.")))
            ], required: []).serializedData(pretty: false))),
            requestedSchema(name: "shelf_entry", toolClass: .read, capabilities: ["app_data_write", "external_send", "notification", "tool_call"], description: "Open a helper's latest settled reply by bot or name, including its full answer, artifacts and actual run status. Or pass id for one exact saved reply; optional bot_id verifies its owner. Marks only the returned entry read by default; mark_read false leaves unread state unchanged. save_to a folder also saves the reply's attached files there.", parametersJSON: (try! object([("id", ToolSchema.nullable(ToolSchema.strSchema("Exact shelf entry UUID; omit to read the latest reply for a named bot."))), ("bot_id", ToolSchema.nullable(ToolSchema.strSchema("Bot name or UUID when selecting its latest reply; with id, the expected bot UUID."))), ("bot", ToolSchema.nullable(id)), ("name", ToolSchema.nullable(id)), ("mark_read", ToolSchema.nullable(ToolSchema.boolSchema("Mark the returned entry read. Default true; false reads without acknowledgement."))), ("save_to", ToolSchema.nullable(ToolSchema.strSchema("Folder to save the reply's attached files into, as Save does on the Helpers shelf. Each file keeps its own name; a file already there is never replaced. A folder outside the trusted workspace asks the person for file access.")))], required: []).serializedData(pretty: false)))
        ]
    }
}
