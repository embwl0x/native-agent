import Foundation
import PersistenceCore
import StandingBots

extension SwiftToolDispatcher {
    /// Shared across chat surfaces, separate from every UI reader. Sparse IDs,
    /// never the page token, are persisted as the agent's acknowledgement.
    static let standingBotReaderID = "agent"

    func impl_standingBots(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let shelf = ShelfStore(dataRoot: dataRoot)
        do {
            let args = input.filter { !["__session_id", "session_id"].contains($0.key) }
            switch tool {
            case "bot_ask":
                try botKeys(args, allowed: ["id", "question"])
                guard allowsCanonicalBodyTools else { throw BotRunnerError.notPermitted }
                let answer = try await StandingBotContinuity.ask(dataRoot: dataRoot,
                    bot: botID(args["id"]), question: botString(args["question"], field: "question"),
                    lifecycleObserver: providerLifecycleObserver)
                return .object(["answer": .string(answer)])
            case "shelf_documents":
                try botKeys(args, allowed: ["bot", "offset", "limit"])
                let offset = try botOptional(args["offset"]).map { try botDecode(Int.self, $0, field: "offset") } ?? 0
                let limit = try botOptional(args["limit"]).map { try botDecode(Int.self, $0, field: "limit") } ?? 20
                return try botJSON(BotContinuityStore(dataRoot: dataRoot).list(bot: botID(args["bot"]), offset: offset, limit: limit))
            case "shelf_document":
                try botKeys(args, allowed: ["bot", "name", "version", "offset", "limit"])
                let offset = try botOptional(args["offset"]).map { try botDecode(Int.self, $0, field: "offset") } ?? 0
                let limit = try botOptional(args["limit"]).map { try botDecode(Int.self, $0, field: "limit") } ?? 4_000
                let version = try botOptional(args["version"]).map { try botID($0) }
                return try botJSON(BotContinuityStore(dataRoot: dataRoot).read(bot: botID(args["bot"]),
                    name: botString(args["name"], field: "name"), version: version, offset: offset, limit: limit))
            case "bot_create":
                try botKeys(args, allowed: ["name", "brief", "cadence", "sources", "budget", "output_format"])
                let bot = BotDefinition(name: try botString(args["name"], field: "name"),
                                        brief: try botString(args["brief"], field: "brief"),
                                        cadence: try botCadence(args["cadence"]),
                                        sources: try await botSources(args["sources"], dataRoot: dataRoot),
                                        budget: try botBudget(args["budget"]),
                                        outputFormat: try botOptional(args["output_format"]).map { try botDecode(String.self, $0, field: "output_format") })
                return try botJSON(definitions.create(bot))
            case "bot_update":
                try botKeys(args, allowed: ["id", "fields"])
                let fields = try botObject(args["fields"], field: "fields")
                try botKeys(fields, allowed: ["name", "brief", "cadence", "sources", "budget", "output_format"])
                let edits = fields.filter { $0.value != .null }
                guard !edits.isEmpty else { throw StandingBotsError.invalidValue("fields must contain at least one setting") }
                var bot = try definitions.get(botID(args["id"]))
                if let value = edits["name"] { bot.name = try botString(value, field: "name") }
                if let value = edits["brief"] { bot.brief = try botString(value, field: "brief") }
                if let value = edits["cadence"] { bot.cadence = try botCadence(value) }
                if let value = edits["sources"] { bot.sources = try await botSources(value, dataRoot: dataRoot) }
                if let value = edits["output_format"] { bot.outputFormat = try botDecode(String.self, value, field: "output_format") }
                if let value = edits["budget"] { bot.budget = try botBudget(value) }
                return try botJSON(definitions.update(bot))
            case "bot_pause":
                try botKeys(args, allowed: ["id", "paused"])
                let paused = try botDecode(Bool.self, args["paused"], field: "paused")
                return try botJSON(definitions.pause(botID(args["id"]), paused: paused))
            case "bot_list":
                try botKeys(args, allowed: [])
                return .object(["bots": try botJSON(definitions.list())])
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
                        "runHealth": .string(row.runHealth.rawValue),
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
            return .object(["status": .string("rejected"), "reason": .string(error.rawValue)])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "detail": .string(String(describing: error))])
        }
    }
}

private func botOptional(_ value: JSONValue?) -> JSONValue? { value == .null ? nil : value }

private func botSources(_ value: JSONValue?, dataRoot: URL) async throws -> [BotSource] {
    let sources = try botDecode([BotSource].self, value, field: "sources (HTTP URL strings, {type:http,url}, or {type:tool,name})")
    for source in sources {
        switch source {
        case .tool(let name): try await StandingBotToolPolicy.validate(name: name, input: [:], dataRoot: dataRoot)
        case .http(let address):
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw StandingBotsError.invalidValue("Source \(address) refused: use a public http(s) URL or a catalog read-only tool source; private destinations are not allowed.")
            }
        }
    }
    return sources
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
    guard object.count == 1 else { throw StandingBotsError.invalidValue("cadence requires exactly one of interval or cron") }
    try botKeys(object, allowed: ["interval", "cron"])
    if let interval = object["interval"] {
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
