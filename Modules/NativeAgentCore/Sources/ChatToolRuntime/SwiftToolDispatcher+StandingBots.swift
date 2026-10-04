import AgentWorkspace
import Dispatcher
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots
import ToolRegistry

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
    func standingBotsArgumentRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        guard tool == "bot_create" || tool == "bot_update" else { return nil }
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let args = input.filter { !["__session_id", "session_id"].contains($0.key) }
        do {
            let candidate = tool == "bot_create"
                ? try await botCreateCandidate(args)
                : try await botUpdateCandidate(args, definitions: definitions)
            // The cadence floor and the rest of the persisted-shape rules, from
            // the store itself rather than a second copy of them here.
            do {
                try botCheck(candidate, definitions: definitions, input: tool == "bot_create" ? args : try botObject(args["fields"], field: "fields"))
            } catch let error as ToolFailureError {
                throw tool == "bot_update" ? botFieldsError(error) : error
            }
            return nil
        } catch {
            var result = ChatToolOutcome.failure(error: error, tool: tool)
            if case .object(var fields) = result {
                fields["reason"] = .string("invalid_arguments")
                fields["failure_code"] = .string("invalid_arguments")
                fields["detail"] = .string(ChatToolOutcome.errorMessage(error))
                fields["effects"] = .string("none")
                fields.removeValue(forKey: "remedy")
                result = ChatToolOutcome.normalizedFailure(.object(fields), tool: tool)
            }
            return result
        }
    }

    /// The bot bot_create would write. Shared by dispatch and the pre-approval
    /// check; it touches no file.
    private func botCreateCandidate(_ args: [String: JSONValue]) async throws -> BotDefinition {
        let args = args.filter { $0.value != .null && (["output_format", "schedule", "timezone"].contains($0.key) || $0.value != .string("")) }
        try botKeys(args, allowed: ["name", "brief", "cadence", "schedule", "timezone", "details", "provider", "model", "reasoning_effort", "fast", "daily_token_ceiling", "budget", "output_format", "paused", "event_trigger", "notify_condition"])
        _ = try botDetails(args)
        var bot = BotDefinition(name: try botString(args["name"], field: "name"),
                                brief: try botString(args["brief"], field: "brief"),
                                cadence: try botRequestedCadence(args) ?? .manual,
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
        bot.paused = try args["paused"].map { try botDecode(Bool.self, $0, field: "paused") } ?? false
        bot.dailyTokenCeiling = try args["daily_token_ceiling"].map { try botDecode(Int.self, $0, field: "daily_token_ceiling") }
        bot.eventTrigger = try args["event_trigger"].map(botEventTrigger)
        if bot.eventTrigger != nil, bot.cadence != .manual { throw botTriggerTimingError }
        bot.notificationCondition = try args["notify_condition"].map { try botString($0, field: "notify_condition") }
        return bot
    }

    /// The bot bot_update would write, read from the store and edited in
    /// memory. Shared by dispatch and the pre-approval check; it writes nothing.
    private func botUpdateCandidate(_ args: [String: JSONValue], definitions: BotDefinitionStore) async throws -> BotDefinition {
        try botKeys(args, allowed: Set(botReferenceKeys + ["fields", "details"]))
        _ = try botDetails(args)
        let fields = try botObject(args["fields"], field: "fields")
        try botKeys(fields, allowed: ["name", "brief", "cadence", "schedule", "timezone", "provider", "model", "reasoning_effort", "fast", "daily_token_ceiling", "budget", "output_format", "event_trigger", "notify_condition"], path: "$.fields")
        let edits = fields.filter { $0.value != .null && (["output_format", "schedule", "timezone", "notify_condition"].contains($0.key) || $0.value != .string("")) }
        guard !edits.isEmpty else { throw botArgumentError("fields must contain at least one setting", field: "fields", accepted: "An object containing at least one setting to change.") }
        var bot = try definitions.get(botReference(args, definitions: definitions))
        do {
            if let value = edits["name"] { bot.name = try botString(value, field: "name") }
            if let value = edits["brief"] { bot.brief = try botString(value, field: "brief") }
            // One "When" choice, as in the Bots editor: a schedule replaces an
            // event trigger, and an event trigger replaces the schedule.
            let timing = try botRequestedCadence(edits)
            if let timing { bot.cadence = timing; bot.eventTrigger = nil }
            if let value = edits["event_trigger"] {
                guard timing == nil || timing == .manual else { throw botTriggerTimingError }
                bot.eventTrigger = try botEventTrigger(value)
                bot.cadence = .manual
            }
            if let value = edits["notify_condition"] {
                let text = try botDecode(String.self, value, field: "notify_condition")
                bot.notificationCondition = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
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
        } catch let error as ToolFailureError {
            throw botFieldsError(error)
        }
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
            throw ToolFailureError("A bot runs on the model it is made with, not Chat's: \(reason)",
                argumentPath: "$", accepted: "An explicit connected provider, model and supported reasoning_effort tuple from bot_list with include_models true.", effects: .none)
        }
    }

    /// shelf_entry save_to: the Save button on a Helpers shelf artifact. Each
    /// inline file is written into the folder under its own name; a file
    /// already there is never replaced. The folder passes the gate write_file
    /// passes: trusted workspace roots, or anywhere under Full Mac file access.
    private func shelfSave(_ artifacts: [BotArtifact], folder: String, surface: String) async throws -> JSONValue {
        let anywhere = await fullMacToolAccess(surface: surface).fileOpsAllowed
        var rows: [JSONValue] = []
        for artifact in artifacts {
            let name = URL(fileURLWithPath: artifact.name).lastPathComponent
            var row: [String: JSONValue] = ["name": .string(artifact.name)]
            defer { rows.append(.object(row)) }
            guard artifact.path.isEmpty else {
                row["status"] = .string("on_disk"); row["path"] = .string(artifact.path)
                continue
            }
            guard let encoded = artifact.base64, let data = Data(base64Encoded: encoded),
                  !["", ".", "..", "/"].contains(name) else {
                row["status"] = .string("unavailable"); row["detail"] = .string("No saved file content.")
                continue
            }
            let target = (folder as NSString).appendingPathComponent(name)
            let url: URL
            if anywhere {
                // write_file's Full Mac spelling: workspace/ alias, ~, and a
                // relative folder under the same root its writes land in.
                let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
                let path = Self.normalizeFullMacPathArgument(Self.normalizeWorkspaceAlias(target, workspaceRoot: workspaceRoot))
                let base = Self.builderSourceRepoRoot(dataRoot: dataRoot) ?? workspaceRoot
                url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
                    .standardizedFileURL.resolvingSymlinksInPath()
            } else {
                do { url = try await resolveTrustedFilePath(target, includeRepoSandbox: false) }
                catch {
                    if let need = fileOpsNeedEnvelope(tool: "shelf_entry", mode: .write, path: target, error: error) { return need }
                    throw error
                }
            }
            // The sensitive-subtree fence every file tool keeps, Full Mac or not.
            guard !connectorPathIsSensitiveData(url.resolvingSymlinksInPath(), dataRoot: dataRoot) else {
                throw StandingBotsError.invalidValue("save_to is inside the app's protected data (credentials, pairing, Trust policy); nothing was saved. Choose a folder outside it, such as one in the workspace.")
            }
            row["path"] = .string(url.path)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                row["status"] = .string("exists"); row["detail"] = .string("A file is already there and was not replaced. Pass another save_to folder.")
                continue
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
            row["status"] = .string("saved"); row["byte_size"] = .int(Int64(data.count))
        }
        return .array(rows)
    }

    func impl_standingBots(tool: String, input: [String: JSONValue], surface: String = "chat") async throws -> JSONValue {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let shelf = ShelfStore(dataRoot: dataRoot)
        do {
            let args = input.filter { !["__session_id", "session_id"].contains($0.key) }
            switch tool {
            case "bot_ask":
                // "message", "text" and "prompt" are what a message is called everywhere else.
                var args = args
                if args["question"] == nil, let key = ["message", "text", "prompt"].first(where: { args[$0] != nil }) {
                    args["question"] = args.removeValue(forKey: key)
                }
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
                let candidate = try await botCreateCandidate(args)
                let created: BotDefinition
                do { created = try definitions.create(candidate) }
                catch let error as ToolFailureError { throw botTimingError(error, input: args) }
                return try botDefinitionJSON(created,
                    details: botDetails(args), operation: (args["schedule"] ?? .null) == .null
                        && (args["cadence"] ?? .null) == .null && created.eventTrigger == nil ? "created without timing" : "created")
            case "bot_update":
                let candidate = try await botUpdateCandidate(args, definitions: definitions)
                let updated: BotDefinition
                do { updated = try definitions.update(candidate) }
                catch let error as ToolFailureError {
                    throw botFieldsError(botTimingError(error, input: try botObject(args["fields"], field: "fields")))
                }
                return try botDefinitionJSON(updated,
                    details: botDetails(args), operation: "updated")
            case "bot_delete":
                try botKeys(args, allowed: Set(botReferenceKeys))
                try definitions.delete(botReference(args, definitions: definitions))
                return .object(["status": .string("deleted"), "detail": .string("The session and saved replies are kept.")])
            case "bot_pause":
                try botKeys(args, allowed: Set(botReferenceKeys + ["paused", "details"]))
                let paused = try botDecode(Bool.self, args["paused"], field: "paused")
                let details = try botDetails(args)
                return try botDefinitionJSON(definitions.pause(botReference(args, definitions: definitions), paused: paused),
                    details: details, operation: paused ? "paused" : "resumed")
            case "bot_list":
                try botKeys(args, allowed: ["details", "include_models", "id"])
                let details = try botDetails(args)
                let includeModels = try args["include_models"].map { try botDecode(Bool.self, $0, field: "include_models") } ?? false
                let selected = try args["id"].map { _ in try definitions.get(botReference(args, definitions: definitions)) }
                var result: [String: JSONValue] = ["status": .string("ok"), "bots": .array(try (selected.map { [$0] } ?? definitions.list()).map {
                    try botDefinitionJSON($0, details: details)
                })]
                if includeModels { result["model_choices"] = try await SwiftNativeProviderRouting(dataRoot: dataRoot).botModelChoices() }
                return .object(result)
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
                let args = args.filter { $0.value != .null && $0.value != .string("") }
                try botKeys(args, allowed: ["id", "bot_id", "bot", "name", "save_to"])
                let selection = args.filter { $0.key != "save_to" }
                let savedEntry: ShelfEntry
                if let id = selection["id"] {
                    savedEntry = try shelf.entry(botID(id))
                    if let expected = selection["bot_id"], savedEntry.botId != (try botID(expected)) {
                        throw StandingBotsError.invalidValue("This shelf entry belongs to a different bot. Use the exact message_id returned by the selected bot.")
                    }
                    let named = selection.filter { $0.key == "bot" || $0.key == "name" }
                    if !botSuppliedReferences(named).isEmpty,
                       savedEntry.botId != (try botReference(named, definitions: definitions)) {
                        throw StandingBotsError.invalidValue("This shelf entry belongs to a different bot.")
                    }
                } else {
                    let selected = try definitions.get(botReference(selection, definitions: definitions))
                    guard let latest = try shelf.entriesByBot()[selected.id]?.last(where: {
                        !$0.uncertainties.contains("Run receipt pending finalization.")
                    }) else {
                        return .object(["status": .string("empty"), "agent_name": .string(selected.name),
                            "session_id": .string(selected.sessionID),
                            "detail": .string("No settled reply yet. This does not start or repeat a run.")])
                    }
                    savedEntry = latest
                }
                // Through the shared approval boundary: an approval decided
                // from Telegram or the iPhone settles here too, so the tool
                // never reports waitingForApproval on a decided approval.
                let entry = shelf.reconciling([savedEntry])[0]
                var saved: JSONValue?
                if let folder = args["save_to"] {
                    saved = try await shelfSave(entry.artifacts ?? [], folder: botString(folder, field: "save_to"), surface: surface)
                    // Outside the trusted workspace: the person's file-access card, as write_file raises.
                    if let saved, InlineInteractionNeed.interaction(in: saved) != nil { return saved }
                }
                var result = try botJSON(entry)
                if case .object(var fields) = result {
                    fields["status"] = .string("ok")
                    fields["answer"] = .string(entry.actualReply)
                    fields["run_status"] = .string(entry.runtimeStatus.rawValue)
                    fields["status_detail"] = entry.statusDetail.map(JSONValue.string) ?? .null
                    if let name = try? definitions.get(entry.botId).name {
                        fields["agent_name"] = .string(name)
                    }
                    if let saved { fields["saved"] = saved }
                    result = .object(fields)
                }
                try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: [entry.id])
                return result
            case "shelf_read":
                let args = args.filter { $0.value != .string("") }
                try botKeys(args, allowed: ["id", "bot", "bot_id", "name", "since", "topic", "limit", "cursor", "include_read", "newest_first", "mark_read"])
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
                let includeRead = try args["include_read"].flatMap { $0 == .null ? nil : $0 }
                    .map { try botDecode(Bool.self, $0, field: "include_read") } ?? false
                let newestFirst = try args["newest_first"].flatMap { $0 == .null ? nil : $0 }
                    .map { try botDecode(Bool.self, $0, field: "newest_first") } ?? false
                let markRead = try args["mark_read"].flatMap { $0 == .null ? nil : $0 }
                    .map { try botDecode(Bool.self, $0, field: "mark_read") } ?? false
                let page = try shelf.shelfRead(bot: bot, since: since, topic: topic, limit: limit,
                                              cursor: cursor, readerId: includeRead ? nil : Self.standingBotReaderID, newestFirst: newestFirst)
                // One definition read for this page, including an unfiltered
                // shelf. A missing/deleted helper keeps its exact saved ID.
                let agentNames = Dictionary(uniqueKeysWithValues: ((try? definitions.list()) ?? []).map { ($0.id, $0.name) })
                var shortenedChange = false
                // Entries first, then the approval boundary (which reads the
                // pending set last), so a remotely decided approval settles for
                // this reader exactly as it does on the Mac page.
                let reconciled = shelf.reconciling(try page.rows.map { try shelf.entry($0.id) })
                let rows: [JSONValue] = try zip(page.rows, reconciled).map { row, entry in
                    shortenedChange = shortenedChange || entry.changedSinceLastGood.count > 240
                    return .object([
                        "id": .string(row.id.uuidString), "bot": .string(row.botId.uuidString),
                        "agent_name": agentNames[row.botId].map(JSONValue.string) ?? .null,
                        "runAt": try botJSON(row.runAt), "headline": .string(row.headline),
                        "status": .string(entry.runtimeStatus.rawValue),
                        "session_id": .string(entry.sessionID ?? "bot-" + entry.botId.uuidString.lowercased()),
                        "changedSinceLastGood": .string(String(entry.changedSinceLastGood.prefix(240))),
                    ])
                }
                let result: JSONValue = .object([
                    "status": .string("ok"),
                    "view": .string(includeRead ? "saved_replies" : "unread_replies"),
                    "order": .string(newestFirst ? "newest_first" : "oldest_first"),
                    "entries": .array(rows), "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
                    "truncated": .bool(page.truncated || shortenedChange),
                ])
                // Finish every read and response conversion before acknowledging.
                // Lookahead rows, filtered rows and unread earlier gaps stay unread.
                if markRead, !page.rows.isEmpty {
                    try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: page.rows.map(\.id))
                }
                return result
            default:
                throw StandingBotsError.invalidValue("unknown bots tool")
            }
        } catch let error as BotRunAdmissionError {
            return .object(["status": .string("unavailable"), "reason": .string(error.rawValue)])
        } catch let error as ToolFailureError {
            var result = ChatToolOutcome.failure(error: error, tool: tool)
            if case .object(var fields) = result {
                fields["reason"] = .string("bots_tool_failed")
                fields["failure_code"] = .string("bots_tool_failed")
                fields["detail"] = .string(ChatToolOutcome.errorMessage(error))
                result = .object(fields)
            }
            return result
        } catch {
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "detail": .string(ChatToolOutcome.errorMessage(error))])
        }
    }
}

private func botArgumentError(_ message: String, field: String, accepted: String) -> ToolFailureError {
    ToolFailureError(message, argumentPath: "$." + field, accepted: accepted, effects: .none)
}

private func botFieldsError(_ error: ToolFailureError) -> ToolFailureError {
    ToolFailureError(error.message, argumentPath: error.argumentPath.map { "$.fields" + $0.dropFirst() },
        accepted: error.accepted, effects: error.effects)
}

private func botTimingError(_ error: ToolFailureError, input: [String: JSONValue]) -> ToolFailureError {
    if let schedule = input["schedule"], schedule != .null, error.argumentPath?.hasPrefix("$.cadence") == true {
        return botArgumentError(error.message, field: "schedule", accepted: "A schedule string: every N minutes or every N hours, with positive integer N and an interval meeting the reported minimum.")
    }
    return error
}

private func botCheck(_ candidate: BotDefinition, definitions: BotDefinitionStore, input: [String: JSONValue]) throws {
    do { try definitions.check(candidate) }
    catch let error as ToolFailureError {
        throw botTimingError(error, input: input)
    }
}

private func botKeys(_ object: [String: JSONValue], allowed: Set<String>, path: String = "$") throws {
    let unknown = Set(object.keys).subtracting(allowed)
    guard unknown.isEmpty else {
        throw ToolFailureError("unknown fields: " + unknown.sorted().joined(separator: ", "),
            argumentPath: path + "." + unknown.sorted()[0], accepted: "Allowed fields: " + allowed.sorted().joined(separator: ", "), effects: .none)
    }
}

private func botObject(_ value: JSONValue?, field: String) throws -> [String: JSONValue] {
    guard case .object(let object) = value else { throw botArgumentError(field + " must be an object", field: field, accepted: "An object.") }
    return object
}

private func botDecode<T: Decodable>(_ type: T.Type, _ value: JSONValue?, field: String) throws -> T {
    var shape = type == Bool.self ? "A boolean." : type == Int.self ? "An integer." : type == String.self ? "A string."
        : type == BotBudget.self ? "An object with tokens: positive integer and seconds: positive finite number."
        : type == BotCadence.self ? "An object with exactly one of manual: {}, interval: {seconds: number}, or cron: {expression: string, timeZone: string}."
        : "An object matching " + field + "."
    guard let value else { throw botArgumentError("missing " + field, field: field, accepted: shape) }
    do { return try JSONDecoder().decode(type, from: value.serializedData(pretty: false)) }
    catch {
        let keys: [String]
        switch error {
        case DecodingError.keyNotFound(let key, let context): keys = context.codingPath.map(\.stringValue) + [key.stringValue]
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context): keys = context.codingPath.map(\.stringValue)
        default: keys = []
        }
        let path = ([field] + keys).joined(separator: ".")
        switch path {
        case "budget.tokens": shape = "A positive integer."
        case "budget.seconds": shape = "A positive finite number."
        case "cadence.interval.seconds": shape = "A finite number of seconds meeting the bot cadence minimum."
        case "cadence.cron.expression": shape = "A cron expression string."
        case "cadence.cron.timeZone": shape = "An IANA timezone string."
        default: break
        }
        throw botArgumentError("invalid \(path); expected: \(shape)", field: path, accepted: shape)
    }
}

private func botString(_ value: JSONValue?, field: String) throws -> String {
    let text = try botDecode(String.self, value, field: field)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw botArgumentError("empty " + field, field: field, accepted: "A nonblank string.") }
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
func botReference(_ args: [String: JSONValue], definitions: BotDefinitionStore) throws -> UUID {
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
    try botKeys(object, allowed: ["tokens", "seconds"], path: "$.budget")
    return try botDecode(BotBudget.self, value, field: "budget")
}

/// The Bots editor's "On an event", checked the way the editor checks it.
private func botEventTrigger(_ value: JSONValue?) throws -> BotEventTrigger {
    let object = try botObject(value, field: "event_trigger").filter { $0.value != .null }
    try botKeys(object, allowed: ["source", "filter", "keyword"], path: "$.event_trigger")
    let raw = try botString(object["source"], field: "event_trigger.source")
    guard let source = BotEventSource(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
        throw botArgumentError("event_trigger.source must be github or slack", field: "event_trigger.source", accepted: "github or slack.")
    }
    let filter = try botString(object["filter"], field: "event_trigger.filter").trimmingCharacters(in: .whitespacesAndNewlines)
    // Slack delivers a channel ID, never a name, so a name would never match.
    if source == .slack, !BotEventTrigger.isChannelID(filter) {
        throw botArgumentError("A Slack trigger needs the channel ID, such as C0123ABCD, not its name. In Slack, open the channel, choose View channel details, and copy the ID at the bottom.", field: "event_trigger.filter", accepted: "A Slack channel ID such as C0123ABCD.")
    }
    let keyword = try object["keyword"].map { try botDecode(String.self, $0, field: "event_trigger.keyword") }
    return BotEventTrigger(source: source, filter: source == .slack ? filter.uppercased() : filter, keyword: keyword)
}

private var botTriggerTimingError: ToolFailureError { botArgumentError(
    "An event-woken helper keeps no schedule: the event is what runs it. Drop schedule and cadence, or use schedule manual.",
    field: "event_trigger", accepted: "event_trigger with no schedule, or with schedule manual.") }

private func botCadence(_ value: JSONValue?) throws -> BotCadence {
    // The null siblings are not branches. `{"interval":{…},"manual":null,
    // "cron":null}` is one cadence, and refusing it as "exactly one of…" sent
    // the model round the retry loop with nothing to change. Dropped before
    // the count AND before the decode: the synthesized enum decoder wants a
    // single key too.
    let shape = "An object with exactly one of manual: {}, interval: {seconds: number}, or cron: {expression: string, timeZone: string}."
    guard case .object(let raw) = value else { throw botArgumentError("cadence must be an object", field: "cadence", accepted: shape) }
    let object = raw.filter { $0.value != .null }
    guard object.count == 1 else { throw botArgumentError("cadence requires exactly one of manual, interval or cron", field: "cadence", accepted: shape) }
    try botKeys(object, allowed: ["manual", "interval", "cron"], path: "$.cadence")
    if let manual = object["manual"] {
        guard case .object(let fields) = manual, fields.isEmpty else {
            throw botArgumentError("manual must be an empty object; use cadence: {\"manual\":{}} or schedule: \"manual\"", field: "cadence.manual", accepted: "An empty object: {}.")
        }
    } else if let interval = object["interval"] {
        try botKeys(botObject(interval, field: "cadence.interval"), allowed: ["seconds"], path: "$.cadence.interval")
    } else {
        try botKeys(botObject(object["cron"], field: "cadence.cron"), allowed: ["expression", "timeZone"], path: "$.cadence.cron")
    }
    return try botDecode(BotCadence.self, .object(object), field: "cadence")
}

/// Both pre-approval and persistence call this adapter; cadence validity and
/// the operator's minimum interval still belong to BotDefinitionStore.
private func botRequestedCadence(_ args: [String: JSONValue]) throws -> BotCadence? {
    let args = args.filter { $0.value != .null }
    guard args["schedule"] != nil else {
        guard args["timezone"] == nil else {
            throw botArgumentError("timezone requires a daily or weekdays schedule; legacy cron uses its own timeZone", field: "timezone", accepted: "Supply timezone only with a daily, weekday or weekly schedule; cron uses cadence.cron.timeZone.")
        }
        return try args["cadence"].map(botCadence)
    }
    guard args["cadence"] == nil else {
        throw botArgumentError("Use schedule or cadence, not both", field: "schedule", accepted: "Supply schedule or cadence, not both.")
    }
    do {
        return try StandingBotSchedule.parse(
            botString(args["schedule"], field: "schedule"),
            timezone: args["timezone"].map { try botString($0, field: "timezone") })
    } catch StandingBotsError.invalidValue(let message) {
        throw ToolFailureError(message, argumentPath: "$", accepted: "schedule: manual; every N minutes or hours; daily at HH:mm; weekdays at HH:mm; weekly on DAY at HH:mm. Clock: 00:00-23:59. Optional timezone: an IANA name for daily, weekday or weekly timing.", effects: .none)
    }
}

private func botDetails(_ args: [String: JSONValue]) throws -> Bool {
    guard let value = args["details"], value != .null else { return false }
    return try botDecode(Bool.self, value, field: "details")
}

private func botJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
}

private func botDefinitionJSON(_ bot: BotDefinition, details: Bool = false, operation: String? = nil) throws -> JSONValue {
    guard case .object(var fields) = try botJSON(bot) else { throw StandingBotsError.invalidValue("bot") }
    if !details {
        let visible: Set<String> = ["id", "name", "brief", "provider", "model", "reasoningEffort", "fast",
                                   "cadence", "paused", "budget", "outputFormat", "eventTrigger", "notificationCondition"]
        fields = fields.filter { visible.contains($0.key) }
    }
    fields["status"] = .string("ok")
    fields["session_id"] = .string(bot.sessionID)
    fields["daily_token_ceiling"] = .int(Int64(bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens))
    fields["schedule"] = .string(StandingBotSchedule.describe(bot.cadence))
    fields["output_format"] = .string(bot.outputFormat ?? "")
    if case .cron(_, let zone) = bot.cadence { fields["timezone"] = .string(zone) }
    fields["scheduler_status"] = .string(bot.paused ? "paused" : bot.eventTrigger != nil ? "on_event" : bot.cadence == .manual ? "manual" : "scheduled")
    let reference = JSONValue.string(bot.name)
    // Each is her app call: these tools are app actions now.
    let actions: [String: JSONValue] = [
        "talk": .object(["tool": .string("agent_message"),
            "input": .object(["agent": reference, "text": .string("<your message>")])]),
        "open_reply": .object(["tool": .string("agent_read"), "input": .object(["agent": reference])]),
        "run_once": .object(["tool": .string("bot_run_once"), "input": .object(["bot": reference])]),
        bot.paused ? "resume" : "pause": .object(["tool": .string("bot_pause"),
            "input": .object(["bot": reference, "paused": .bool(!bot.paused)])])
    ]
    fields["actions"] = .object(actions.mapValues(ToolNameAliases.appPointer))
    if let operation {
        fields["operation"] = .string(operation)
        switch operation {
        case "created without timing" where bot.paused:
            fields["operation"] = .string("created")
            fields["detail"] = .string("Saved paused as manual; this call did not run the helper. No timing was given: ask the person when it should run, such as daily at 09:00, weekdays at 08:30 or weekly on monday at 09:00, then set it with bot_update schedule. Manual messages and run once remain available.")
        case "created" where bot.paused:
            fields["operation"] = .string("created")
            fields["detail"] = .string("Saved paused; this call did not run the helper. Scheduled turns stay paused until resumed with bot_pause paused false. Manual messages and run once remain available.")
        case "created":
            fields["detail"] = .string("Saved; this call did not run the helper. Send a message or run once when ready. Scheduled turns follow the saved timing.")
        case "created without timing":
            fields["operation"] = .string("created")
            fields["detail"] = .string("Saved as manual; this call did not run the helper. No timing was given: ask the person when it should run, such as daily at 09:00, weekdays at 08:30 or weekly on monday at 09:00, then set it with bot_update schedule.")
        case "paused":
            fields["detail"] = .string("Scheduled turns are paused. Any in-flight run is not cancelled. Manual messages and run once remain available; context and saved replies are preserved.")
        case "resumed":
            fields["detail"] = .string(bot.cadence == .manual
                ? "Unpaused with the same context and saved replies. Timing is manual, so no scheduled run was started."
                : "Scheduled turns are enabled with the same context and saved replies. This call did not start a run.")
        default:
            fields["detail"] = .string("Settings saved. The existing session and saved replies are preserved; this call did not start a run.")
        }
    }
    fields.removeValue(forKey: "sources")
    return .object(fields)
}
