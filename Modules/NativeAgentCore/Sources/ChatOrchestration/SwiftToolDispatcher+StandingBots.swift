import Foundation
import PersistenceCore
import ProviderRouting
import StandingBots

extension SwiftToolDispatcher {
    func standingBotApprovalReason(tool: String, input: [String: JSONValue]) -> String? {
        guard tool == "bot_delete" else { return nil }
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        guard let id = try? botReference(input, definitions: definitions),
              let bot = try? definitions.get(id) else { return "Delete this bot? Its saved notes stay." }
        return "Delete the bot \(bot.name)? Its saved notes stay."
    }

    /// Shared across chat surfaces, separate from every UI reader. Sparse IDs,
    /// never the page token, are persisted as the agent's acknowledgement.
    static let standingBotReaderID = "agent"

    /// Every argument check bot_create / bot_update run, with nothing written:
    /// key and shape validation, the cadence floor, and the same route check
    /// the run gate applies. nil when the call would be accepted.
    ///
    /// Called twice for one call, and deliberately so. The approval membrane
    /// (`AutonomyGatedDispatcher`) runs it BEFORE it files a card, so a
    /// malformed call comes back to the model as an ordinary tool error instead
    /// of costing the person a click and failing after it (2026-09-13, the
    /// 0.4.12 drive: `{cadence:"900"}` raised a card and only then said cadence
    /// must be an object). The dispatch below runs the same builders again on
    /// the way to the store — one function, so the two can never disagree.
    func standingBotsArgumentProblem(tool: String, input: [String: JSONValue]) async -> String? {
        guard tool == "bot_create" || tool == "bot_update" else { return nil }
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let args = input.filter { !["__session_id", "session_id"].contains($0.key) }
        do {
            let candidate = tool == "bot_create"
                ? try await botCreateCandidate(args)
                : try await botUpdateCandidate(args, definitions: definitions)
            // The cadence floor and the rest of the persisted-shape rules, from
            // the store itself rather than a second copy of them here.
            try definitions.check(candidate)
            return nil
        } catch StandingBotsError.invalidValue(let message) {
            return message
        } catch {
            return ChatToolOutcome.errorMessage(error)
        }
    }

    /// The bot bot_create would write. Shared by dispatch and the pre-approval
    /// check; it touches no file.
    private func botCreateCandidate(_ args: [String: JSONValue]) async throws -> BotDefinition {
        let args = args.filter { $0.value != .null && ($0.key == "output_format" || $0.value != .string("")) }
        try botKeys(args, allowed: ["name", "brief", "cadence", "provider", "model", "reasoning_effort", "fast", "daily_token_ceiling", "budget", "output_format"])
        var bot = BotDefinition(name: try botString(args["name"], field: "name"),
                                brief: try botString(args["brief"], field: "brief"),
                                cadence: try args["cadence"].map(botCadence) ?? .manual,
                                budget: try args["budget"].map(botBudget)
                                    ?? BotBudget(tokens: BotRunLimits.maximumTokens, seconds: BotRunLimits.maximumSeconds),
                                outputFormat: try args["output_format"].map { try botDecode(String.self, $0, field: "output_format") })
        // User, 2026-09-13: "Bots has no default model; Agent is supposed
        // to pick the model when she makes one." A bot runs on the model
        // it was made with — there is no inheritance from Chat — so a
        // create with no route or model is refused, by name.
        bot.provider = try args["provider"].map { try botString($0, field: "provider") }
        bot.model = try args["model"].map { try botString($0, field: "model") }
        bot.reasoningEffort = try args["reasoning_effort"].map { try botString($0, field: "reasoning_effort") }
        try await botRouteCheck(bot)
        bot.fast = try args["fast"].map { try botDecode(Bool.self, $0, field: "fast") }
        bot.dailyTokenCeiling = try args["daily_token_ceiling"].map { try botDecode(Int.self, $0, field: "daily_token_ceiling") }
        return bot
    }

    /// The bot bot_update would write, read from the store and edited in
    /// memory. Shared by dispatch and the pre-approval check; it writes nothing.
    private func botUpdateCandidate(_ args: [String: JSONValue], definitions: BotDefinitionStore) async throws -> BotDefinition {
        try botKeys(args, allowed: Set(botReferenceKeys + ["fields"]))
        let fields = try botObject(args["fields"], field: "fields")
        try botKeys(fields, allowed: ["name", "brief", "cadence", "provider", "model", "reasoning_effort", "fast", "daily_token_ceiling", "budget", "output_format"])
        let edits = fields.filter { ($0.key == "output_format" || $0.value != .string("")) }
        guard !edits.isEmpty else { throw StandingBotsError.invalidValue("fields must contain at least one setting") }
        var bot = try definitions.get(botReference(args, definitions: definitions))
        if let value = edits["name"] { bot.name = try botString(value, field: "name") }
        if let value = edits["brief"] { bot.brief = try botString(value, field: "brief") }
        if let value = edits["cadence"] { bot.cadence = try botCadence(value) }
        if let value = edits["provider"] { bot.provider = try botString(value, field: "provider") }
        if let value = edits["model"] { bot.model = try botString(value, field: "model") }
        if let value = edits["reasoning_effort"] { bot.reasoningEffort = try botString(value, field: "reasoning_effort") }
        if let value = edits["fast"] { bot.fast = try botDecode(Bool.self, value, field: "fast") }
        if let value = edits["daily_token_ceiling"] { bot.dailyTokenCeiling = try botDecode(Int.self, value, field: "daily_token_ceiling") }
        if let value = edits["output_format"] { bot.outputFormat = try botDecode(String.self, value, field: "output_format") }
        if let value = edits["budget"] { bot.budget = try botBudget(value) }
        // The edited tuple has to stand on its own, whichever field was
        // touched: changing the provider without the model, or the model
        // without the Think level, would otherwise leave a bot that
        // cannot run (2026-09-13 review).
        try await botRouteCheck(bot)
        return bot
    }

    /// The live route check — the exact closure the app installs into
    /// `BotRunGate` at launch (NativeAgentApp.swift), so a tuple refused here is
    /// refused identically by a scheduled run and by `BotChatContract`.
    private func botRouteCheck(_ bot: BotDefinition) async throws {
        if let reason = await SwiftNativeProviderRouting(dataRoot: dataRoot)
            .botChoiceRejection(
                provider: bot.provider, model: bot.model,
                reasoningEffort: bot.reasoningEffort
            ) {
            throw StandingBotsError.invalidValue(
                "A bot runs on the model it is made with, not Chat's: \(reason)"
            )
        }
    }

    func impl_standingBots(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let shelf = ShelfStore(dataRoot: dataRoot)
        do {
            let args = input.filter { !["__session_id", "session_id"].contains($0.key) }
            switch tool {
            case "bot_ask":
                try botKeys(args, allowed: Set(botReferenceKeys + ["question"]))
                guard allowsCanonicalBodyTools else { throw BotRunnerError.notPermitted }
                guard let standingBotSession else { throw StandingBotsError.invalidValue("Bot chat is unavailable.") }
                let outcome = try await BotRunner(dataRoot: dataRoot, session: standingBotSession).ask(
                    bot: botReference(args, definitions: definitions), question: botString(args["question"], field: "question"))
                // The status travels with the answer. A provider failure used to
                // come back as a bare empty answer with no cause, and a result
                // carrying no status at all reads as success on the
                // approved-replay path. A partial answer is still returned.
                let status = outcome.runtimeStatus
                // The wire words the dispatch trace already grades by, so a
                // failed ask is a failure and an ask stopped on an approval is
                // neither a failure nor progress.
                let wire: String
                switch status {
                case .completed: wire = "completed"
                case .failed: wire = "failed"
                case .interrupted: wire = "interrupted"
                case .waitingForApproval: wire = "waiting_approval"
                case .waitingOnPerson: wire = "waiting_on_you"
                }
                var result: [String: JSONValue] = [
                    "answer": .string(outcome.actualReply), "status": .string(wire),
                    // The exact return address for the run that just happened.
                    // The runner already saved all of this; the handoff used to
                    // drop it, so using a helper's actual output meant another
                    // run or a shelf search.
                    "entry_id": .string(outcome.id.uuidString),
                ]
                if status != .completed, let detail = outcome.statusDetail ?? outcome.uncertainties.first {
                    result["detail"] = .string(detail)
                }
                if let sessionID = outcome.sessionID, !sessionID.isEmpty {
                    result["session_id"] = .string(sessionID)
                }
                if let approvalID = outcome.approvalID, !approvalID.isEmpty {
                    result["approval_id"] = .string(approvalID)
                }
                // References, never bytes: name/path/type, with any inline
                // base64 left in the saved entry. Bounded, so a run that wrote
                // many files cannot flood the answer.
                let artifacts = outcome.artifacts ?? []
                if !artifacts.isEmpty {
                    let shown = artifacts.prefix(8)
                    result["artifacts"] = .array(shown.map { artifact in
                        var row: [String: JSONValue] = [
                            "name": .string(artifact.name), "path": .string(artifact.path),
                        ]
                        if let type = artifact.type { row["type"] = .string(type) }
                        if let mime = artifact.mime { row["mime"] = .string(mime) }
                        if let bytes = artifact.byteSize { row["byte_size"] = .int(Int64(bytes)) }
                        return .object(row)
                    })
                    if artifacts.count > shown.count {
                        result["artifacts_truncated"] = .int(Int64(artifacts.count - shown.count))
                    }
                }
                // The full-detail pull for everything not carried here.
                result["shelf_entry"] = .object([
                    "tool": .string("shelf_entry"), "id": .string(outcome.id.uuidString),
                ])
                return .object(result)
            case "bot_create":
                return try botDefinitionJSON(definitions.create(try await botCreateCandidate(args)))
            case "bot_update":
                return try botDefinitionJSON(definitions.update(try await botUpdateCandidate(args, definitions: definitions)))
            case "bot_delete":
                try botKeys(args, allowed: Set(botReferenceKeys))
                try definitions.delete(botReference(args, definitions: definitions))
                return .object(["status": .string("deleted"), "detail": .string("The session and saved replies are kept.")])
            case "bot_pause":
                try botKeys(args, allowed: Set(botReferenceKeys + ["paused"]))
                let paused = try botDecode(Bool.self, args["paused"], field: "paused")
                return try botDefinitionJSON(definitions.pause(botReference(args, definitions: definitions), paused: paused))
            case "bot_list":
                try botKeys(args, allowed: [])
                return .object(["status": .string("ok"), "bots": .array(try definitions.list().map(botDefinitionJSON))])
            case "bot_run_once":
                try botKeys(args, allowed: Set(botReferenceKeys))
                let bot = try definitions.get(botReference(args, definitions: definitions))
                guard let standingBotRunEnqueue else {
                    return .object(["status": .string("failed"), "reason": .string("run_queue_unavailable"),
                                    "detail": .string("The bot run queue is not connected.")])
                }
                let requestID = try standingBotRunEnqueue(bot.id)
                return .object(["status": .string("queued"), "id": .string(bot.id.uuidString),
                                "requestId": .string(requestID.uuidString)])
            case "shelf_entry":
                let args = args.filter { $0.value != .string("") }
                try botKeys(args, allowed: ["id", "bot_id"])
                let savedEntry = try shelf.entry(botID(args["id"]))
                if let expected = args["bot_id"] {
                    guard savedEntry.botId == (try botID(expected)) else {
                        throw StandingBotsError.invalidValue("This shelf entry belongs to a different bot. Use the exact message_id returned by the selected bot.")
                    }
                }
                // Through the shared approval boundary: an approval decided
                // from Telegram or the iPhone settles here too, so the tool
                // never reports waitingForApproval on a decided approval.
                let entry = shelf.reconciling([savedEntry])[0]
                var result = try botJSON(entry)
                if case .object(var fields) = result {
                    fields["status"] = .string("ok")
                    if let name = try? definitions.get(entry.botId).name {
                        fields["agent_name"] = .string(name)
                    }
                    result = .object(fields)
                }
                try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: [entry.id])
                return result
            case "shelf_read":
                let args = args.filter { $0.value != .string("") }
                try botKeys(args, allowed: ["bot", "bot_id", "name", "since", "topic", "limit", "cursor"])
                let bot = botSuppliedReferences(args).isEmpty
                    ? nil : try botReference(args, definitions: definitions)
                let since = try args["since"].map { value in
                    let text = try botString(value, field: "since")
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let fractional = formatter.date(from: text)
                    formatter.formatOptions = [.withInternetDateTime]
                    guard let date = fractional ?? formatter.date(from: text) else {
                        throw StandingBotsError.invalidValue("since must be an ISO 8601 time with time zone")
                    }
                    return date
                }
                let topic = try args["topic"].map { try botDecode(String.self, $0, field: "topic") }
                let cursor = try args["cursor"].map { try botString($0, field: "cursor") }
                let limit = try args["limit"].map { try botDecode(Int.self, $0, field: "limit") } ?? 20
                let page = try shelf.shelfRead(bot: bot, since: since, topic: topic, limit: limit,
                                              cursor: cursor, readerId: Self.standingBotReaderID)
                let agentName = bot.flatMap { try? definitions.get($0).name }
                var shortenedChange = false
                // Entries first, then the approval boundary (which reads the
                // pending set last), so a remotely decided approval settles for
                // this reader exactly as it does on the Mac page.
                let reconciled = shelf.reconciling(try page.rows.map { try shelf.entry($0.id) })
                let rows: [JSONValue] = try zip(page.rows, reconciled).map { row, entry in
                    shortenedChange = shortenedChange || entry.changedSinceLastGood.count > 240
                    return .object([
                        "id": .string(row.id.uuidString), "bot": .string(row.botId.uuidString),
                        "agent_name": agentName.map(JSONValue.string) ?? .null,
                        "runAt": try botJSON(row.runAt), "headline": .string(row.headline),
                        "status": .string(entry.runtimeStatus.rawValue),
                        "session_id": .string(entry.sessionID ?? "bot-" + entry.botId.uuidString.lowercased()),
                        "changedSinceLastGood": .string(String(entry.changedSinceLastGood.prefix(240))),
                    ])
                }
                let result: JSONValue = .object([
                    "status": .string("ok"),
                    "entries": .array(rows), "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
                    "truncated": .bool(page.truncated || shortenedChange),
                ])
                // Finish every read and response conversion before acknowledging.
                // Lookahead rows, filtered rows and unread earlier gaps stay unread.
                if !page.rows.isEmpty {
                    try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: page.rows.map(\.id))
                }
                return result
            default:
                throw StandingBotsError.invalidValue("unknown bots tool")
            }
        } catch let error as BotRunAdmissionError {
            return .object(["status": .string("unavailable"), "reason": .string(error.rawValue)])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "detail": .string(ChatToolOutcome.errorMessage(error))])
        }
    }
}

private func botKeys(_ object: [String: JSONValue], allowed: Set<String>) throws {
    let unknown = Set(object.keys).subtracting(allowed)
    guard unknown.isEmpty else { throw StandingBotsError.invalidValue("unknown fields: " + unknown.sorted().joined(separator: ", ")) }
}

private func botObject(_ value: JSONValue?, field: String) throws -> [String: JSONValue] {
    guard case .object(let object) = value else { throw StandingBotsError.invalidValue(field + " must be an object") }
    return object
}

private func botDecode<T: Decodable>(_ type: T.Type, _ value: JSONValue?, field: String) throws -> T {
    guard let value else { throw StandingBotsError.invalidValue("missing " + field) }
    do { return try JSONDecoder().decode(type, from: value.serializedData(pretty: false)) }
    catch {
        let examples = ["name": "\"Research\"", "brief": "\"Summarize new issues\"",
                        "question": "\"What changed?\"", "provider": "\"openai\"",
                        "model": "\"gpt-5.6-sol\"", "reasoning_effort": "\"high\"",
                        "fast": "false", "daily_token_ceiling": "16000",
                        "cadence": "{\"manual\":{}}", "budget": "{\"tokens\":2000,\"seconds\":60}"]
        throw StandingBotsError.invalidValue("invalid \(field); example: \(field): \(examples[field] ?? "\"text\"")")
    }
}

private func botString(_ value: JSONValue?, field: String) throws -> String {
    let text = try botDecode(String.self, value, field: field)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StandingBotsError.invalidValue("empty " + field) }
    return text
}

private func botID(_ value: JSONValue?) throws -> UUID {
    guard let id = UUID(uuidString: try botString(value, field: "id")) else { throw StandingBotsError.invalidValue("id must be a UUID") }
    return id
}

/// The keys every bot-identifying tool accepts. Observed 2026-09-14: three
/// bot_ask calls in a row were refused ("unknown fields: bot", then bot_id,
/// then name) before the only accepted spelling was found. A model writing
/// the obvious thing should be right, so all four spellings resolve and the
/// refusal below names them plus the shelf.
private let botReferenceKeys = ["id", "bot_id", "bot", "name"]

/// The bot-naming keys actually PROVIDED. An empty or all-whitespace alias is
/// absent, not a choice: a model that means one spelling routinely emits the
/// other three as `""`, and counting those as provided refused the call with
/// "name the bot once" until it gave up retrying.
private func botSuppliedReferences(_ args: [String: JSONValue]) -> [(key: String, value: JSONValue)] {
    botReferenceKeys.compactMap { key -> (key: String, value: JSONValue)? in
        guard let value = args[key], value != .null else { return nil }
        if case .string(let text) = value,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return (key: key, value: value)
    }
}

/// The bot named by `id` / `bot_id` / `bot` / `name`: a UUID, or a bot name
/// matched case-insensitively — exactly, else by unique prefix.
private func botReference(_ args: [String: JSONValue], definitions: BotDefinitionStore) throws -> UUID {
    let supplied = botSuppliedReferences(args)
    let shelf = (try? definitions.list()) ?? []
    func refuse(_ lead: String) -> StandingBotsError {
        let listed = shelf.isEmpty
            ? "There are no bots yet — make one with bot_create."
            : "Bots: " + shelf.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: "; ")
        return StandingBotsError.invalidValue(
            lead + " Name the bot with id, bot_id, bot or name — a bot ID from bot_list, or the bot's name. " + listed
        )
    }
    guard let first = supplied.first else { throw refuse("No bot named.") }
    if supplied.count > 1 {
        let ids = try supplied.map { try botReference([$0.key: $0.value], definitions: definitions) }
        guard Set(ids).count == 1 else {
            throw refuse("Conflicting bot fields: " + supplied.map(\.key).joined(separator: ", ") + ". Pass id alone, for example id: \"\(ids[0])\".")
        }
        return ids[0]
    }
    let text = try botString(first.value, field: first.key).trimmingCharacters(in: .whitespacesAndNewlines)
    // A blank reference names NOTHING. Left to the prefix match below it would
    // match every bot, so a single-bot shelf would resolve `bot_delete(name: " ")`
    // to that bot and delete it.
    guard !text.isEmpty else { throw refuse("\(first.key) is blank.") }
    if let id = UUID(uuidString: text) { return id }
    let folded = text.lowercased()
    let exact = shelf.filter { $0.name.lowercased() == folded }
    if exact.count == 1 { return exact[0].id }
    if exact.count > 1 { throw refuse("More than one bot is called \"\(text)\"; use its ID.") }
    let prefixed = shelf.filter { $0.name.lowercased().hasPrefix(folded) }
    if prefixed.count == 1 { return prefixed[0].id }
    if prefixed.count > 1 { throw refuse("\"\(text)\" matches more than one bot.") }
    throw refuse("No bot matches \"\(text)\".")
}

private func botBudget(_ value: JSONValue?) throws -> BotBudget {
    let object = try botObject(value, field: "budget")
    try botKeys(object, allowed: ["tokens", "seconds"])
    return try botDecode(BotBudget.self, value, field: "budget")
}

private func botCadence(_ value: JSONValue?) throws -> BotCadence {
    // The null siblings are not branches. `{"interval":{…},"manual":null,
    // "cron":null}` is one cadence, and refusing it as "exactly one of…" sent
    // the model round the retry loop with nothing to change. Dropped before
    // the count AND before the decode: the synthesized enum decoder wants a
    // single key too.
    let object = try botObject(value, field: "cadence").filter { $0.value != .null }
    guard object.count == 1 else { throw StandingBotsError.invalidValue("cadence requires exactly one of manual, interval or cron") }
    try botKeys(object, allowed: ["manual", "interval", "cron"])
    if let manual = object["manual"] {
        try botKeys(botObject(manual, field: "manual"), allowed: [])
    } else if let interval = object["interval"] {
        try botKeys(botObject(interval, field: "interval"), allowed: ["seconds"])
    } else {
        try botKeys(botObject(object["cron"], field: "cron"), allowed: ["expression", "timeZone"])
    }
    return try botDecode(BotCadence.self, .object(object), field: "cadence")
}

private func botJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
}

private func botDefinitionJSON(_ bot: BotDefinition) throws -> JSONValue {
    guard case .object(var fields) = try botJSON(bot) else { throw StandingBotsError.invalidValue("bot") }
    fields["status"] = .string("ok")
    fields["session_id"] = .string(bot.sessionID)
    fields["daily_token_ceiling"] = .int(Int64(bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens))
    fields.removeValue(forKey: "sources")
    return .object(fields)
}
