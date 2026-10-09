import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots

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
        var eventTrigger = object([
            ("source", enumStringSchema(["github", "slack"], "github: a new issue or pull request on a repository. slack: a message in a channel the Slack connector receives.")),
            ("filter", strSchema("The repository as owner/repo, or the Slack channel ID such as C0123ABCD. Slack delivers IDs, never names.")),
            ("keyword", strSchema("Optional word the event text must contain.")),
        ], required: ["source", "filter"])
        if case .object(var trigger) = eventTrigger {
            trigger["description"] = .string("Wake the helper on an outside event, as On an event does in the Bots editor. The event replaces the schedule: the helper keeps no timing of its own. Any later schedule or cadence change removes the trigger. Autonomy off holds an event instead of running it.")
            eventTrigger = .object(trigger)
        }
        let fields: [(String, JSONValue)] = [
            ("name", strSchema("Name chosen for this bot.")),
            ("brief", strSchema("What the bot should do, in the agent's words.")),
            ("output_format", strSchema("Desired output, in the agent's words. Empty means no requested form.")),
            ("provider", strSchema("Connected provider ID. bot_list with include_models true shows configured accounts, model IDs and supported Think choices. Required when making a bot: a bot runs on the route it was made with.")),
            ("model", strSchema("Model this bot runs on. Required when making a bot — pick one the chosen provider serves. A bot does not follow Chat's model.")),
            ("reasoning_effort", strSchema("Think level for this bot. Required when making a bot; must be one the chosen model supports.")),
            ("fast", nullableRecallField(boolSchema())),
            ("schedule", strSchema("Simple timing: manual, every 30 minutes, every 2 hours, daily at 09:00, weekdays at 09:00, or weekly on monday at 09:00. Use 24-hour HH:mm. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Supply schedule OR cadence, never both. Other prose is refused rather than guessed. Example: \"every 30 minutes\".")),
            ("timezone", strSchema("Optional IANA time zone for a daily, weekday or weekly schedule. Omit to persist this Mac's current zone. Set another zone only when the person explicitly requested it; never copy a zone from older jobs or context. Do not supply for manual/interval or alongside cadence; cron uses timeZone.")),
            ("cadence", obj([("description", .string(
                "Advanced timing object; prefer schedule for simple timing. Supply exactly one non-null manual, interval or cron branch, never alongside schedule or timezone. Interval seconds must meet Minimum cadence on the Bots page (60–900 seconds; default 900). cron requires expression; omit timeZone to persist this Mac's current zone. Set another zone only when the person explicitly requested it; never copy a zone from older jobs or context. Example: {\"manual\":{}}."
            )), ("oneOf", .array([
                object([("manual", object([], required: []))], required: ["manual"]),
                object([("interval", object([("seconds", numSchema(minimum: standingBotMinimumInterval))], required: ["seconds"]))], required: ["interval"]),
                object([("cron", object([("expression", strSchema()), ("timeZone", strSchema())], required: ["expression"]))], required: ["cron"])
            ]))])),
            ("budget", object([("tokens", intSchema("Whole-turn output token allowance; measured conservatively across requests.", minimum: 1)),
                ("seconds", intSchema("Maximum run duration.", minimum: 1))], required: ["tokens", "seconds"])),
            ("daily_token_ceiling", intSchema("Daily allowance for this bot. Each run reserves its full token limit.", minimum: 1)),
            // User, 2026-10-01: the Bots editor's "On an event" and "Tell me if",
            // so the agent can set everything the editor sets.
            ("event_trigger", eventTrigger),
            ("notify_condition", strSchema("The Bots editor's Tell me if: after each scheduled, event or run-once run, the helper judges its own result against this condition and the person is notified only when it is met. An empty string clears it.")),
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
            requestedSchema(name: "bot_create", description: "Make a standing helper with its own persistent chat. Required: name, brief, provider, model and reasoning_effort; choose a connected route from bot_list include_models true. Optional schedule accepts simple timing; omitted timing is manual. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Creation saves the helper; it does not run it. Set paused true to pause scheduled turns from creation. details true includes all settings. Example with a connected OpenAI account: {\"name\":\"Research helper\",\"brief\":\"Summarize research when asked.\",\"provider\":\"openai\",\"model\":\"gpt-6.1-sol\",\"reasoning_effort\":\"medium\",\"schedule\":\"manual\"}.", parametersJSON: params(properties: fields.map { ($0.0, createRequired.contains($0.0) ? $0.1 : optional($0.1)) } + [("paused", optional(boolSchema("Start with scheduled turns paused. Default false. Manual messages and run once remain available."))), details], required: createRequired)),
            requestedSchema(name: "bot_update", description: "Change a helper and keep its session and saved replies. Required: a bot reference (id, bot_id, bot or name) and fields with at least one changed setting; unused null fields are ignored. schedule accepts simple timing; intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). Model changes must form a valid provider/model/reasoning_effort choice. details true includes all saved settings. Example for an existing helper: {\"name\":\"Research helper\",\"fields\":{\"schedule\":\"manual\"}}.", parametersJSON: params(properties: botReference + [("fields", object(fields, required: [])), details], required: ["fields"])),
            requestedSchema(name: "bot_pause", description: "Pause or resume a helper's scheduled turns by name and paused (true or false). This does not cancel an in-flight run. Manual follow-ups and run once still work; resuming keeps the same context and saved replies. details true includes all settings.", parametersJSON: params(properties: botReference + [("paused", boolSchema()), details], required: ["paused"])),
            requestedSchema(name: "bot_delete", description: "Remove a bot from the active list and stop its schedule. Keep its session and saved replies. Name the bot by id, bot_id, bot or name.", parametersJSON: params(properties: botReference, required: [])),
            requestedSchema(name: "bot_list", description: "See helpers by name, job, chosen model, resolved schedule and status. Optional id opens one exact helper. include_models true also shows configured provider accounts with model IDs and supported Think levels, for choosing a helper model without searching settings or introspecting Chat. It does not change any choice or test a service. details true includes full bot settings.", parametersJSON: params(properties: [details, ("id", optional(id)), ("include_models", optional(boolSchema()))], required: [])),
            requestedSchema(name: "bot_run_once", description: "Queue the helper's standing job once, including while paused. Name it by id, bot_id, bot or name. Optional question gives this run its input without changing the standing job. When the result says automatic_return true, the app waits and brings the outcome to this initiating conversation; do not poll or resend. The dated reply is also saved on the shelf. Raw calls outside a chat use the shelf to read their result.", parametersJSON: params(properties: botReference + [("question", optional(strSchema("Question or context for this run only.")))], required: [])),
            requestedSchema(name: "bot_ask", description: "Talk to a helper in its existing chat session by name and question. Its current standing brief accompanies every turn; your question does not change that standing job. Returns the reply under current Trust and the helper's chosen model and limits.", parametersJSON: params(properties: botReference.map { ($0.0, nullableRecallField($0.1)) } + [("question", strSchema("Follow-up message."))], required: ["question"])),
            requestedSchema(name: "shelf_read", description: "Read a compact index of saved replies. Defaults to unread replies without changing unread state. Use include_read true to browse history, including previously read answers. Only mark_read true marks returned entries read. Every argument is optional: name one bot by id, bot_id, bot or name, and narrow with since, topic, limit and cursor. Use newest_first true to start with recent saved replies; the default is oldest first. Follow nextCursor with the same filters, including include_read and newest_first.", parametersJSON: params(properties: [
                ("id", nullableRecallField(id)), ("bot_id", nullableRecallField(id)), ("bot", nullableRecallField(id)), ("name", nullableRecallField(id)),
                ("since", nullableRecallField(strSchema("Exclusive start: YYYY-MM-DD (local day) or ISO 8601 time with time zone."))),
                ("topic", nullableRecallField(strSchema("Text to find in replies."))),
                ("limit", nullableRecallField(intSchema(minimum: 1, maximum: 100))),
                ("include_read", optional(boolSchema())),
                ("mark_read", optional(boolSchema("Mark only returned entries read. Default false."))),
                ("newest_first", optional(boolSchema())),
                ("cursor", nullableRecallField(strSchema("nextCursor from the previous page.")))
            ], required: [])),
            requestedSchema(name: "shelf_entry", description: "Open a helper's latest settled reply by bot or name, including its full answer, artifacts and actual run status. Or pass id for one exact saved reply; optional bot_id verifies its owner. Marks only the returned entry read by default; mark_read false leaves unread state unchanged. save_to a folder also saves the reply's attached files there.", parametersJSON: params(properties: [("id", optional(strSchema("Exact shelf entry UUID; omit to read the latest reply for a named bot."))), ("bot_id", optional(strSchema("Bot name or UUID when selecting its latest reply; with id, the expected bot UUID."))), ("bot", optional(id)), ("name", optional(id)), ("mark_read", optional(boolSchema("Mark the returned entry read. Default true; false reads without acknowledgement."))), ("save_to", optional(strSchema("Folder to save the reply's attached files into, as Save does on the Helpers shelf. Each file keeps its own name; a file already there is never replaced. A folder outside the trusted workspace asks the person for file access.")))], required: []))
        ]
    }
}
