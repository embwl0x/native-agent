import Foundation
import PersistenceCore
import ProviderRouting
import StandingBots

extension SwiftToolDispatcher {
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
            return String(describing: error)
        }
    }

    /// The bot bot_create would write. Shared by dispatch and the pre-approval
    /// check; it touches no file.
    private func botCreateCandidate(_ args: [String: JSONValue]) async throws -> BotDefinition {
        try botKeys(args, allowed: ["name", "brief", "cadence", "provider", "model", "reasoning_effort", "fast", "daily_token_ceiling", "budget", "output_format"])
        var bot = BotDefinition(name: try botString(args["name"], field: "name"),
                                brief: try botString(args["brief"], field: "brief"),
                                cadence: try botOptional(args["cadence"]).map(botCadence) ?? .manual,
                                budget: try botOptional(args["budget"]).map(botBudget)
                                    ?? BotBudget(tokens: BotRunLimits.maximumTokens, seconds: BotRunLimits.maximumSeconds),
                                outputFormat: try botOptional(args["output_format"]).map { try botDecode(String.self, $0, field: "output_format") })
        // User, 2026-09-13: "Bots has no default model; Agent is supposed
        // to pick the model when she makes one." A bot runs on the model
        // it was made with — there is no inheritance from Chat — so a
        // create with no route or model is refused, by name.
        bot.provider = try botOptional(args["provider"]).map { try botString($0, field: "provider") }
        bot.model = try botOptional(args["model"]).map { try botString($0, field: "model") }
        bot.reasoningEffort = try botOptional(args["reasoning_effort"]).map { try botString($0, field: "reasoning_effort") }
        try await botRouteCheck(bot)
        bot.fast = try botOptional(args["fast"]).map { try botDecode(Bool.self, $0, field: "fast") }
        bot.dailyTokenCeiling = try botOptional(args["daily_token_ceiling"]).map { try botDecode(Int.self, $0, field: "daily_token_ceiling") }
        return bot
    }

    /// The bot bot_update would write, read from the store and edited in
    /// memory. Shared by dispatch and the pre-approval check; it writes nothing.
    private func botUpdateCandidate(_ args: [String: JSONValue], definitions: BotDefinitionStore) async throws -> BotDefinition {
        try botKeys(args, allowed: ["id", "fields"])
        let fields = try botObject(args["fields"], field: "fields")
        try botKeys(fields, allowed: ["name", "brief", "cadence", "provider", "model", "reasoning_effort", "fast", "daily_token_ceiling", "budget", "output_format"])
        let edits = fields.filter { $0.value != .null }
        guard !edits.isEmpty else { throw StandingBotsError.invalidValue("fields must contain at least one setting") }
        var bot = try definitions.get(botID(args["id"]))
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
                try botKeys(args, allowed: ["id", "question"])
                guard allowsCanonicalBodyTools else { throw BotRunnerError.notPermitted }
                guard let standingBotSession else { throw StandingBotsError.invalidValue("Bot chat is unavailable.") }
                let outcome = try await BotRunner(dataRoot: dataRoot, session: standingBotSession).ask(
                    bot: botID(args["id"]), question: botString(args["question"], field: "question"))
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
                }
                var result: [String: JSONValue] = [
                    "answer": .string(outcome.actualReply), "status": .string(wire),
                ]
                if status != .completed, let detail = outcome.statusDetail ?? outcome.uncertainties.first {
                    result["detail"] = .string(detail)
                }
                return .object(result)
            case "bot_create":
                return try botDefinitionJSON(definitions.create(try await botCreateCandidate(args)))
            case "bot_update":
                return try botDefinitionJSON(definitions.update(try await botUpdateCandidate(args, definitions: definitions)))
            case "bot_delete":
                try botKeys(args, allowed: ["id"])
                try definitions.delete(botID(args["id"]))
                return .object(["status": .string("deleted"), "detail": .string("The session and saved replies are kept.")])
            case "bot_pause":
                try botKeys(args, allowed: ["id", "paused"])
                let paused = try botDecode(Bool.self, args["paused"], field: "paused")
                return try botJSON(definitions.pause(botID(args["id"]), paused: paused))
            case "bot_list":
                try botKeys(args, allowed: [])
                return .object(["bots":  .array(try definitions.list().map(botDefinitionJSON))])
            case "bot_run_once":
                try botKeys(args, allowed: ["id"])
                let bot = try definitions.get(botID(args["id"]))
                guard let standingBotRunEnqueue else {
                    return .object(["status": .string("failed"), "reason": .string("run_queue_unavailable"),
                                    "detail": .string("The bot run queue is not connected.")])
                }
                let requestID = try standingBotRunEnqueue(bot.id)
                return .object(["status": .string("queued"), "id": .string(bot.id.uuidString),
                                "requestId": .string(requestID.uuidString)])
            case "shelf_entry":
                try botKeys(args, allowed: ["id"])
                let entry = try shelf.entry(botID(args["id"]))
                let result = try botJSON(entry)
                try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: [entry.id])
                return result
            case "shelf_read":
                try botKeys(args, allowed: ["bot", "since", "topic", "limit", "cursor"])
                let bot = try botOptional(args["bot"]).map { try botID($0) }
                let since = try botOptional(args["since"]).map { value in
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
                let topic = try botOptional(args["topic"]).map { try botDecode(String.self, $0, field: "topic") }
                let cursor = try botOptional(args["cursor"]).map { try botString($0, field: "cursor") }
                let limit = try botOptional(args["limit"]).map { try botDecode(Int.self, $0, field: "limit") } ?? 20
                let page = try shelf.shelfRead(bot: bot, since: since, topic: topic, limit: limit,
                                              cursor: cursor, readerId: Self.standingBotReaderID)
                var shortenedChange = false
                let rows: [JSONValue] = try page.rows.map { row in
                    let entry = try shelf.entry(row.id)
                    shortenedChange = shortenedChange || entry.changedSinceLastGood.count > 240
                    return .object([
                        "id": .string(row.id.uuidString), "bot": .string(row.botId.uuidString),
                        "runAt": try botJSON(row.runAt), "headline": .string(row.headline),
                        "status": .string(entry.runtimeStatus.rawValue),
                        "session_id": .string(entry.sessionID ?? "bot-" + entry.botId.uuidString.lowercased()),
                        "changedSinceLastGood": .string(String(entry.changedSinceLastGood.prefix(240))),
                    ])
                }
                let result: JSONValue = .object([
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
                            "detail": .string(String(describing: error))])
        }
    }
}

private func botOptional(_ value: JSONValue?) -> JSONValue? { value == .null ? nil : value }

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
    catch { throw StandingBotsError.invalidValue("invalid " + field) }
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

private func botBudget(_ value: JSONValue?) throws -> BotBudget {
    let object = try botObject(value, field: "budget")
    try botKeys(object, allowed: ["tokens", "seconds"])
    return try botDecode(BotBudget.self, value, field: "budget")
}

private func botCadence(_ value: JSONValue?) throws -> BotCadence {
    let object = try botObject(value, field: "cadence")
    guard object.count == 1 else { throw StandingBotsError.invalidValue("cadence requires exactly one of manual, interval or cron") }
    try botKeys(object, allowed: ["manual", "interval", "cron"])
    if let manual = object["manual"] {
        try botKeys(botObject(manual, field: "manual"), allowed: [])
    } else if let interval = object["interval"] {
        try botKeys(botObject(interval, field: "interval"), allowed: ["seconds"])
    } else {
        try botKeys(botObject(object["cron"], field: "cron"), allowed: ["expression", "timeZone"])
    }
    return try botDecode(BotCadence.self, value, field: "cadence")
}

private func botJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
}

private func botDefinitionJSON(_ bot: BotDefinition) throws -> JSONValue {
    guard case .object(var fields) = try botJSON(bot) else { throw StandingBotsError.invalidValue("bot") }
    fields["session_id"] = .string(bot.sessionID)
    fields["daily_token_ceiling"] = .int(Int64(bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens))
    fields.removeValue(forKey: "sources")
    return .object(fields)
}
