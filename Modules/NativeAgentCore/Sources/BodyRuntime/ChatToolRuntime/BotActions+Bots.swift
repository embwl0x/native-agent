import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `BotActions+Bots.swift` | bots action contracts and execution |

enum BotActions {}

protocol StandingBotArgs: DoorArgs {}

extension StandingBotArgs {
    static var rootSchemaConstraints: [String: JSONValue] { ["additionalProperties": .bool(false)] }
    static func isTransportMetadata(_ key: String) -> Bool { key == "__session_id" || key == "session_id" }
}

extension BotActions {
    static func standingBotActions(minimumInterval: TimeInterval?) -> [ActionDescriptor] {
        [
            ActionDescriptor(BotCreateArgs.self, name: "bot_create",
                fields: BotCreateArgs.fields(minimumInterval: minimumInterval),
                preflight: { await $0.client.standingBotsArgumentRefusal(tool: $0.tool, input: .create($1)) },
                run: { context, args in
                    try await context.client.impl_standingBots(context, .create(args))
                }, toolClass: .write, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Make a standing helper with its own persistent conversation. Required: name and brief. It follows Providers for Chat unless an \
                explicit provider/model/reasoning_effort choice pins it. bot.list include_models true shows connected choices. Optional schedule \
                accepts simple timing; omitted timing is manual. Intervals must meet Minimum cadence on the Bots page (1–15 minutes; default 15). \
                Creation saves the helper; it does not run it. Set paused true to pause scheduled turns from creation. details true includes all \
                settings. Example: {\"name\":\"Research helper\",\"brief\":\"Summarize research when asked.\",\"schedule\":\"manual\"}.
                """),
            ActionDescriptor(BotUpdateArgs.self, name: "bot_update",
                fields: BotUpdateArgs.fields(minimumInterval: minimumInterval),
                preflight: { await $0.client.standingBotsArgumentRefusal(tool: $0.tool, input: .update($1)) },
                run: { context, args in
                    try await context.client.impl_standingBots(context, .update(args))
                }, toolClass: .write, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Change a helper and keep its conversation and saved replies. Required: id (helper UUID or exact name) and fields with at least one \
                changed setting; unused null fields are ignored. schedule accepts simple timing; intervals must meet Minimum cadence on the Bots \
                page (1–15 minutes; default 15). Model changes must form a valid provider/model/reasoning_effort choice. provider, reasoning_effort \
                and fast apply only to a pinned model; followers use Chat's values, and matching submitted values are no-ops with a note. details \
                true includes all saved settings. Example for an existing helper: {\"id\":\"Research helper\",\"fields\":{\"schedule\":\"manual\"}}.
                """),
            ActionDescriptor(BotPauseArgs.self, name: "bot_pause",
                run: { context, args in
                    try await context.client.impl_standingBots(context, .pause(args))
                }, toolClass: .write, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Pause or resume scheduled turns using id and paused (true or false). A helper without a schedule refuses with effects none. This \
                does not cancel an in-flight run. Manual follow-ups and run once still work; resuming keeps the same context and saved replies. \
                details true includes all settings. Example: {\"id\":\"Research helper\",\"paused\":true}.
                """),
            ActionDescriptor(BotDeleteArgs.self, name: "bot_delete",
                approvalReason: { root, _, input in SwiftToolDispatcher.standingBotApprovalReason(input: input, dataRoot: root) },
                run: { context, args in
                    try await context.client.impl_standingBots(context, .delete(args))
                }, toolClass: .write, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Delete a helper using id (UUID or exact name) and stop future runs. Keep its definition and audit for owned run settlement, \
                conversation and saved replies. Example: {\"id\":\"Research helper\"}.
                """),
            ActionDescriptor(BotListArgs.self, name: "bot_list",
                run: { context, args in
                    try await context.client.impl_standingBots(context, .list(args))
                }, toolClass: .read, capabilities: [.externalSend, .notification, .safeRead, .toolCall], description: """
                See helpers by name, job, chosen model, resolved schedule and status. Optional id opens one exact helper. include_models true also \
                shows configured provider accounts with model IDs and supported Think levels, for choosing a helper model without searching \
                settings or introspecting Chat. It does not change any choice or test a service. details true includes full bot settings.
                """),
            ActionDescriptor(BotRunOnceArgs.self, name: "bot_run_once",
                run: { context, args in
                    try await context.client.impl_standingBots(context, .runOnce(args))
                }, toolClass: .write, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Queue the helper's standing job once using id, including while paused. Optional question gives this run its input without changing \
                the standing job. With automatic_return true, success or failure returns as one line with its bot.reply shelf reference in the \
                initiating conversation, through the peer reply-delivery path; do not poll or resend. Delivery needs no second model turn. Raw \
                calls outside a chat use the shelf. Example: {\"id\":\"Research helper\"}.
                """),
            ActionDescriptor(BotAskArgs.self, name: "bot_ask",
                run: { context, args in
                    try await context.client.impl_standingBots(context, .ask(args))
                }, toolClass: .write, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall], description: """
                Talk to a helper in its existing conversation using id and question. Its current standing brief accompanies every turn; your \
                question does not change that standing job. Returns the reply under current Trust and the helper's chosen model and limits.
                """),
            ActionDescriptor(ShelfReadArgs.self, name: "shelf_read",
                run: { context, args in
                    try await context.client.impl_standingBots(context, .shelfRead(args))
                }, toolClass: .read, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Read saved replies newest first by default, including already read replies. sort accepts newest_first, oldest_first or \
                oldest_unread; oldest_unread explicitly selects unread replies oldest first. include_read false selects unread replies in the \
                chosen order. Only mark_read true marks returned entries read. Optional id selects one helper; since and topic narrow results. Page \
                with offset (default 0, follow next_offset) or cursor (follow nextCursor), never both, keeping the same filters and sort. Headlines \
                end at a word.
                """),
            ActionDescriptor(ShelfEntryArgs.self, name: "shelf_entry",
                run: { context, args in
                    try await context.client.impl_standingBots(context, .shelfEntry(args))
                }, toolClass: .read, capabilities: [.appDataWrite, .externalSend, .notification, .toolCall],
                description: """
                Open a helper's latest settled reply by bot_id, including its full answer, artifacts and actual run status. Or pass id for one \
                exact saved reply; optional bot_id verifies its owner. Marks only the returned entry read by default; mark_read false leaves unread \
                state unchanged. save_to a folder also saves the reply's attached files there.
                """)
        ]
    }
}

struct BotPauseArgs: StandingBotArgs {
    static let idField = BotDeleteArgs.idField
    static let pausedField = DoorFieldDescriptor("paused", ToolSchema.boolSchema(), required: true)
    static let detailsField = BotListArgs.detailsField
    static let doorFields = [idField, pausedField, detailsField]

    let id: String
    let paused: Bool
    let details: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.string(Self.idField)!
        paused = try door.bool(Self.pausedField)!
        details = try door.bool(Self.detailsField)
    }
}

struct BotDeleteArgs: StandingBotArgs {
    static let idField = DoorFieldDescriptor.string("id", "Which helper: id is its UUID from bot.list, or its exact name.", required: true)
    static let doorFields = [idField]

    let id: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.string(Self.idField)!
    }
}

struct BotListArgs: StandingBotArgs {
    static let detailsField = DoorFieldDescriptor("details", ToolSchema.nullable(ToolSchema.boolSchema()), required: false)
    static let idField = DoorFieldDescriptor(BotDeleteArgs.idField.name, ToolSchema.nullable(BotDeleteArgs.idField.schema), required: false)
    static let includeModelsField = DoorFieldDescriptor("include_models", ToolSchema.nullable(ToolSchema.boolSchema()), required: false)
    static let doorFields = [detailsField, idField, includeModelsField]

    let details: Bool?
    let id: String?
    let includeModels: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        details = try door.bool(Self.detailsField)
        id = try door.string(Self.idField)
        includeModels = try door.bool(Self.includeModelsField)
    }
}

struct BotRunOnceArgs: StandingBotArgs {
    static let idField = BotDeleteArgs.idField
    static let questionField = DoorFieldDescriptor("question", ToolSchema.nullable(ToolSchema.strSchema("Question or context for this run only.")), required: false)
    static let doorFields = [idField, questionField]

    let id: String
    let question: String?

    init(id: String) {
        self.id = id
        question = nil
    }

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.string(Self.idField)!
        question = try door.string(Self.questionField)
    }
}

struct BotAskArgs: StandingBotArgs {
    static let idField = BotDeleteArgs.idField.nullable()
    static let questionField = DoorFieldDescriptor.string("question", "Follow-up message.", required: true)
    static let doorFields = [idField, questionField]

    let id: String?
    let question: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.string(Self.idField)
        question = try door.string(Self.questionField)!
    }
}

struct ShelfReadArgs: StandingBotArgs {
    static let idField = BotListArgs.idField
    static let sinceField = DoorFieldDescriptor("since", ToolSchema.nullable(ToolSchema.strSchema("Exclusive start: YYYY-MM-DD (local day) or ISO 8601 time with time zone.")), required: false)
    static let topicField = DoorFieldDescriptor("topic", ToolSchema.nullable(ToolSchema.strSchema("Text to find in replies.")), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.nullable(ToolSchema.intSchema(minimum: 1, maximum: 100)), required: false)
    static let includeReadField = DoorFieldDescriptor("include_read", ToolSchema.nullable(ToolSchema.boolSchema()), required: false)
    static let markReadField = DoorFieldDescriptor("mark_read", ToolSchema.nullable(ToolSchema.boolSchema("Mark only returned entries read. Default false.")), required: false)
    static let sortField = DoorFieldDescriptor("sort", ToolSchema.nullable(ToolSchema.enumStringSchema(["newest_first", "oldest_first", "oldest_unread"],
        "Default newest_first; oldest_unread selects unread only.")), required: false)
    static let offsetField = DoorFieldDescriptor("offset", ToolSchema.nullable(ToolSchema.intSchema("Zero-based offset in matching replies. Use without cursor.", minimum: 0)), required: false)
    static let cursorField = DoorFieldDescriptor("cursor", ToolSchema.nullable(ToolSchema.strSchema("nextCursor from the previous page.")), required: false)
    static let doorFields = [
        idField, sinceField, topicField, limitField, includeReadField, markReadField,
        sortField, offsetField, cursorField
    ]

    let id: String?
    let since: String?
    let topic: String?
    let limit: Int?
    let includeRead: Bool?
    let markRead: Bool?
    let sort: String?
    let offset: Int?
    let cursor: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        _ = door.omit { _, value in value == .string("") }
        id = try door.string(Self.idField)
        since = try door.string(Self.sinceField)
        topic = try door.string(Self.topicField)
        limit = try door.int(Self.limitField)
        includeRead = try door.bool(Self.includeReadField)
        markRead = try door.bool(Self.markReadField)
        sort = try door.string(Self.sortField)
        offset = try door.int(Self.offsetField)
        cursor = try door.string(Self.cursorField)
    }
}

struct ShelfEntryArgs: StandingBotArgs {
    static let idField = DoorFieldDescriptor("id", ToolSchema.nullable(ToolSchema.strSchema("Exact shelf entry UUID; omit to read the latest reply for a named bot.")), required: false)
    static let botIDField = DoorFieldDescriptor("bot_id", ToolSchema.nullable(ToolSchema.strSchema("Bot name or UUID when selecting its latest reply; with id, the expected bot UUID.")), required: false)
    static let markReadField = DoorFieldDescriptor("mark_read", ToolSchema.nullable(ToolSchema.boolSchema("Mark the returned entry read. Default true; false reads without acknowledgement.")), required: false)
    static let saveToField = DoorFieldDescriptor("save_to", ToolSchema.nullable(ToolSchema.strSchema("""
        Folder to save the reply's attached files into, as Save does on the Helpers shelf. Each file keeps its own name; a file already \
        there is never replaced. A folder outside the trusted workspace asks the person for file access.
        """)), required: false)
    static let doorFields = [idField, botIDField, markReadField, saveToField]

    let id: String?
    let botID: String?
    let markRead: Bool?
    let saveTo: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        _ = door.omit { _, value in value == .string("") }
        id = try door.string(Self.idField)
        botID = try door.string(Self.botIDField)
        markRead = try door.bool(Self.markReadField)
        saveTo = try door.string(Self.saveToField)
    }
}

struct BotCreateArgs: StandingBotArgs {
    static let pausedField = DoorFieldDescriptor("paused", ToolSchema.nullable(ToolSchema.boolSchema("""
                Start with scheduled turns paused. Default false. Manual messages and run once remain available.
                """)), required: false)
    static let detailsField = BotListArgs.detailsField
    static func fields(minimumInterval: TimeInterval?) -> [DoorFieldDescriptor] {
        BotSettingsFields.fields(name: BotSettingsFields.nameField, brief: BotSettingsFields.briefField, minimumInterval: minimumInterval).all + [pausedField, detailsField]
    }
    static let doorFields = fields(minimumInterval: nil)

    let settings: BotSettingsFields
    let paused: Bool?
    let details: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        _ = door.omit { key, value in key != "schedule" && value == .string("") && Self.doorFields.contains { $0.name == key } }
        settings = try BotSettingsFields(door: &door)
        paused = try door.bool(Self.pausedField)
        details = try door.bool(Self.detailsField)
    }
}

struct BotUpdateArgs: StandingBotArgs {
    static let idField = BotDeleteArgs.idField
    static let detailsField = BotListArgs.detailsField
    static func fields(minimumInterval: TimeInterval?) -> [DoorFieldDescriptor] {
        let settings = BotSettingsFields.edits(minimumInterval: minimumInterval)
        let schema = DoorArgsContract(fields: settings.all, constraints: BotSettingsFields.constraints).schema
        return [idField, DoorFieldDescriptor("fields", schema, required: true), detailsField]
    }
    static let doorFields = fields(minimumInterval: nil)

    let id: String
    let settings: BotSettingsFields
    let details: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.string(Self.idField)!
        settings = try door.object(door.declaredField("fields"), as: BotSettingsFields.self)!
        details = try door.bool(Self.detailsField)
    }
}

struct BotBudgetFields: DoorObjectSchema {
    static let tokensField = DoorFieldDescriptor("tokens", ToolSchema.intSchema("Whole-turn output token allowance; measured conservatively across requests.", minimum: 1), required: true)
    static let doorFields = NonEmptyFields(tokensField)
    let value: BotBudget

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        value = BotBudget(tokens: try door.int(Self.tokensField)!)
    }
}

struct BotIntervalFields: DoorObjectSchema {
    static func secondsField(minimum: TimeInterval?) -> DoorFieldDescriptor {
        DoorFieldDescriptor("seconds", ActionDescriptor.numSchema(minimum: minimum), required: true)
    }
    static let doorFields = NonEmptyFields(secondsField(minimum: nil))
    let seconds: Double

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        seconds = try door.number(door.declaredField("seconds"))!
    }
}

struct BotCronFields: DoorObjectSchema {
    static let expressionField = DoorFieldDescriptor.string("expression", required: true)
    static let doorFields = NonEmptyFields(expressionField)
    let expression: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        expression = try door.string(Self.expressionField)!
    }
}

struct BotCadenceFields: DoorObjectSchema {
    static let manualField = DoorFieldDescriptor.emptyObject("manual", declaresRequired: true)
    static let cronField = DoorFieldDescriptor.object("cron", BotCronFields.self)
    static func intervalField(_ minimum: TimeInterval?) -> DoorFieldDescriptor {
        let seconds = BotIntervalFields.secondsField(minimum: minimum)
        let schema = DoorArgsContract(fields: [seconds], constraints: BotIntervalFields.constraints).schema
        return DoorFieldDescriptor("interval", schema, required: false)
    }
    static let doorFields = NonEmptyFields(manualField, intervalField(nil), cronField)
    let value: BotCadence
    let omittedNullBranches: [String]

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        omittedNullBranches = door.omit { _, value in value == .null }
        let manual = try door.emptyObject(Self.manualField)
        let interval = try door.object(door.declaredField("interval"), as: BotIntervalFields.self)
        let cron = try door.object(Self.cronField, as: BotCronFields.self)
        switch (manual, interval, cron) {
        case (true, nil, nil): value = .manual
        case (false, let interval?, nil): value = .interval(seconds: interval.seconds)
        case (false, nil, let cron?): value = .cron(expression: cron.expression)
        default: throw DoorDecodeError(path: door.path, accepted: "exactly one of manual, interval or cron")
        }
    }
}

struct BotEventFields: DoorObjectSchema {
    static let sourceField = DoorFieldDescriptor("source", ToolSchema.enumStringSchema(["slack"], "slack: a message in a channel the Slack connector receives."), required: true)
    static let filterField = DoorFieldDescriptor.string("filter", "The Slack channel ID such as C0123ABCD. Slack delivers IDs, never names.", required: true)
    static let keywordField = DoorFieldDescriptor("keyword", ToolSchema.nullable(ToolSchema.strSchema("Optional word the event text must contain.")), required: false)
    static let doorFields = NonEmptyFields(sourceField, filterField, keywordField)

    let source: String
    let filter: String
    let keyword: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        _ = door.omit { _, value in value == .null }
        source = try door.string(Self.sourceField, normalizing: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })!
        filter = try door.string(Self.filterField)!
        keyword = try door.string(Self.keywordField)
    }
}

struct BotSettingsFields: DoorObjectSchema {
    static let nameField = DoorFieldDescriptor.string("name", "Name chosen for this bot.", required: true)
    static let personalityField = DoorFieldDescriptor.string("personality", """
        Who this helper is: its own personality, voice and character, in your words. It is its own someone, never you. Omit for a helper \
        defined by its job alone.
        """)
    static let briefField = DoorFieldDescriptor.string("brief", "The helper's complete job, including any desired output form, in the agent's words.", required: true)
    static let providerField = DoorFieldDescriptor.string("provider", """
        Connected provider ID for a pinned model. bot.list include_models true shows accounts and model choices. Omit provider, model, \
        reasoning_effort and fast to follow Providers for Chat.
        """)
    static let modelField = DoorFieldDescriptor.string("model", """
        An explicit model choice pins this helper to that model. Supply its provider and supported reasoning_effort. Omit to follow \
        Providers for Chat.
        """)
    static let modelPinnedField = DoorFieldDescriptor("model_pinned", ToolSchema.boolSchema("""
        False follows Providers for Chat and clears the saved provider/model/Think/Fast choice. Conflicting per-helper settings in the same \
        call are refused; matching inherited values are accepted as no-ops with a note. True pins the supplied choice. Creation defaults to \
        following Providers unless model is explicitly supplied.
        """), required: false)
    static let reasoningEffortField = DoorFieldDescriptor.string("reasoning_effort", "Supported Think level for a pinned model. Followers use Providers for Chat's Think level.")
    static let fastField = DoorFieldDescriptor("fast", ToolSchema.boolSchema("Fast service tier; only for a pinned model — a helper that follows Providers uses Chat's"), required: false)
    static let scheduleField = DoorFieldDescriptor.string("schedule", """
        Simple timing: manual, every 30 minutes, every 2 hours, daily at 09:00, weekdays at 09:00, or weekly on monday at 09:00. Use \
        24-hour HH:mm on this Mac's local clock; times follow the Mac when it changes zone. Intervals must meet Minimum cadence on the Bots \
        page (1–15 minutes; default 15). Supply schedule OR cadence, never both. Other prose is refused rather than guessed. Example: \
        \"every 30 minutes\".
        """)
    static let dailyTokenCeilingField = DoorFieldDescriptor("daily_token_ceiling", ToolSchema.intSchema("Daily allowance for this bot. Each run reserves its full token limit.", minimum: 1), required: false)
    static let notifyConditionField = DoorFieldDescriptor.string("notify_condition", """
        The Bots editor's Tell me if: after each scheduled, event or run-once run, the helper judges its own result against this condition \
        and the person is notified only when it is met. An empty string clears it.
        """)
    static let budgetField = DoorFieldDescriptor.object("budget", BotBudgetFields.self)
    static let eventTriggerField = DoorFieldDescriptor.object("event_trigger", BotEventFields.self, description: """
                Wake the helper on an outside event, as On an event does in the Bots editor. The event replaces the schedule: the helper keeps no \
                timing of its own. Any later schedule or cadence change removes the trigger. Autonomy off holds an event instead of running it.
                """)

    static func cadenceField(_ minimumInterval: TimeInterval?) -> DoorFieldDescriptor {
        let interval = BotCadenceFields.intervalField(minimumInterval)
        return DoorFieldDescriptor("cadence", .object([
            "description": .string("""
                    Advanced timing object; prefer schedule for simple timing. Supply exactly one non-null manual, interval or cron branch, never \
                    alongside schedule. Interval seconds must meet Minimum cadence on the Bots page (60–900 seconds; default 900). cron requires \
                    expression, read on this Mac's local clock. Example: {\"manual\":{}}.
                    """),
            "type": .string("object"), "additionalProperties": .bool(false), "minProperties": .int(1), "maxProperties": .int(1),
            "properties": ToolSchema.obj([("manual", BotCadenceFields.manualField.schema),
                (interval.name, interval.schema), ("cron", BotCadenceFields.cronField.schema)])
        ]), required: false)
    }

    static func fields(name: DoorFieldDescriptor, brief: DoorFieldDescriptor, minimumInterval: TimeInterval?) -> NonEmptyFields {
        NonEmptyFields(name,
            personalityField.nullable(),
            brief,
            providerField.nullable(),
            modelField.nullable(),
            modelPinnedField.nullable(),
            reasoningEffortField.nullable(),
            fastField.nullable(),
            scheduleField.nullable(),
            cadenceField(minimumInterval).nullable(),
            budgetField.nullable(),
            dailyTokenCeilingField.nullable(),
            eventTriggerField.nullable(),
            notifyConditionField.nullable())
    }

    static func edits(minimumInterval: TimeInterval?) -> NonEmptyFields {
        fields(name: DoorFieldDescriptor(nameField.name, ToolSchema.nullable(nameField.schema), required: false),
               brief: DoorFieldDescriptor(briefField.name, ToolSchema.nullable(briefField.schema), required: false),
               minimumInterval: minimumInterval)
    }

    static let doorFields = edits(minimumInterval: nil)

    let name: String?
    let personality: String?
    let brief: String?
    let provider: String?
    let model: String?
    let modelPinned: Bool?
    let reasoningEffort: String?
    let fast: Bool?
    let schedule: String?
    let cadence: BotCadenceFields?
    let budget: BotBudgetFields?
    let dailyTokenCeiling: Int?
    let eventTrigger: BotEventFields?
    let notifyCondition: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        name = try door.string(door.declaredField(Self.nameField.name)).flatMap { $0.isEmpty ? nil : $0 }
        personality = try door.string(door.declaredField(Self.personalityField.name)).flatMap { $0.isEmpty ? nil : $0 }
        brief = try door.string(door.declaredField(Self.briefField.name)).flatMap { $0.isEmpty ? nil : $0 }
        provider = try door.string(door.declaredField(Self.providerField.name)).flatMap { $0.isEmpty ? nil : $0 }
        model = try door.string(door.declaredField(Self.modelField.name)).flatMap { $0.isEmpty ? nil : $0 }
        modelPinned = try door.bool(door.declaredField(Self.modelPinnedField.name))
        reasoningEffort = try door.string(door.declaredField(Self.reasoningEffortField.name)).flatMap { $0.isEmpty ? nil : $0 }
        fast = try door.bool(door.declaredField(Self.fastField.name))
        schedule = try door.string(door.declaredField(Self.scheduleField.name))
        cadence = try door.object(door.declaredField("cadence"), as: BotCadenceFields.self)
        budget = try door.object(door.declaredField(Self.budgetField.name), as: BotBudgetFields.self)
        dailyTokenCeiling = try door.int(door.declaredField(Self.dailyTokenCeilingField.name))
        eventTrigger = try door.object(door.declaredField(Self.eventTriggerField.name), as: BotEventFields.self)
        notifyCondition = try door.string(door.declaredField(Self.notifyConditionField.name))
    }

    var hasEdit: Bool {
        name != nil || personality != nil || brief != nil || provider != nil || model != nil || modelPinned != nil ||
            reasoningEffort != nil || fast != nil || schedule != nil || cadence != nil || budget != nil ||
            dailyTokenCeiling != nil || eventTrigger != nil || notifyCondition != nil
    }

    var submittedModelSettings: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.providerField.name] = provider.map(JSONValue.string)
        fields[Self.modelField.name] = model.map(JSONValue.string)
        fields[Self.reasoningEffortField.name] = reasoningEffort.map(JSONValue.string)
        fields[Self.fastField.name] = fast.map(JSONValue.bool)
        return fields
    }
}
