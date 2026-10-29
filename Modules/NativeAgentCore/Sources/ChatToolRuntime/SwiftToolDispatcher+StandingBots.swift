import AgentWorkspace
import Dispatcher
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots
import ToolRegistry
import TurnTrace
// Blueprint: | `SwiftToolDispatcher+StandingBots.swift` | `SwiftToolDispatcher`: `standingBotApprovalReason`, `standingBotsArgumentRefusal`, `impl_standingBots` |

extension SwiftToolDispatcher {
    func standingBotApprovalReason(tool: String, input: [String: JSONValue]) -> String? {
        guard tool == "bot_delete" else { return nil }
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        guard let id = try? botReference(input, definitions: definitions, reportShim: false),
              let bot = try? definitions.get(id) else { return "Delete this bot? Its saved notes stay." }
        return "Delete the bot \(bot.name)? Its saved notes stay."
    }

    /// Shared across chat surfaces, separate from every UI reader. Sparse IDs,
    /// never the page token, are persisted as the agent's acknowledgement.
    static let standingBotReaderID = "agent"

    /// The same builders validate shape, cadence and route before approval and again before writing.
    func standingBotsArgumentRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        guard tool == "bot_create" || tool == "bot_update" else { return nil }
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        do {
            let args = try botArguments(tool: tool, input: input, reportShim: false)
            let candidate = tool == "bot_create"
                ? try await botCreateCandidate(args)
                : try await botUpdateCandidate(args, definitions: definitions, reportShim: false)
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

    /// The declared closed tree owns shape; references and stores own admission.
    private func botArguments(tool: String, input: [String: JSONValue], reportShim: Bool = true) throws -> [String: JSONValue] {
        var args = input.filter { !["__session_id", "session_id"].contains($0.key) && $0.value != .null }
        if tool == "bot_create" { args = args.filter { ["output_format", "schedule"].contains($0.key) || $0.value != .string("") } }
        if ["shelf_read", "shelf_entry"].contains(tool) { args = args.filter { $0.value != .string("") } }
        var fields = tool == "bot_update" ? args["fields"] : .object(args)
        if case .object(var object) = fields {
            if case .object(let cadence)? = object["cadence"] {
                object["cadence"] = .object(cadence.filter { $0.value != .null })
                if reportShim, cadence.values.contains(.null) {
                    TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T21"), "site": .string("SwiftToolDispatcher+StandingBots.swift:botCadence")]))
                }
            }
            if case .object(var trigger)? = object["event_trigger"], case .string(let source)? = trigger["source"] {
                trigger = trigger.filter { $0.value != .null }
                trigger["source"] = .string(source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                object["event_trigger"] = .object(trigger)
            }
            fields = .object(object)
            if tool == "bot_update" { args["fields"] = fields } else { args = object }
        }
        guard let declared = BuiltInToolSchemaFactory(requestedNames: [tool]).standingBotSchemas().compactMap({ $0 }).first else {
            throw ToolFailureError("Helper schema is unavailable: \(tool)", effects: .none)
        }
        let schema = try JSONValue.parse(declared.parametersJSON)
        args = ToolArguments.normalized(args, schema: schema, recordShims: reportShim)
        var validation = args
        if ["bot_update", "bot_pause", "bot_delete", "bot_run_once", "bot_ask"].contains(tool) {
            validation["id"] = botSuppliedReferences(args).first?.value
            for key in botReferenceKeys where key != "id" { validation.removeValue(forKey: key) }
        }
        if let problem = JSONValue.object(validation).schemaProblem(schema: schema, path: "$") {
            throw ToolFailureError("\(problem.path) must be \(problem.expected)", argumentPath: problem.path, accepted: problem.expected, effects: .none)
        }
        return args
    }

    /// The bot bot_create would write. Shared by dispatch and the pre-approval
    /// check; it touches no file.
    private func botCreateCandidate(_ args: [String: JSONValue]) async throws -> BotDefinition {
        _ = try botDetails(args)
        var bot = BotDefinition(name: try botString(args["name"], field: "name"),
                                brief: try botString(args["brief"], field: "brief"),
                                cadence: try botRequestedCadence(args) ?? .manual,
                                budget: try args["budget"].map { try botDecode(BotBudget.self, $0, field: "budget") }
                                    ?? BotBudget(tokens: BotRunLimits.maximumTokens, seconds: BotRunLimits.maximumSeconds),
                                outputFormat: try args["output_format"].map { try botDecode(String.self, $0, field: "output_format") })
        bot.personality = try args["personality"].map { try botString($0, field: "personality") }
        bot.provider = try args["provider"].map { try botString($0, field: "provider") }
        bot.model = try args["model"].map { try botString($0, field: "model") }
        bot.reasoningEffort = try args["reasoning_effort"].map { try botString($0, field: "reasoning_effort") }
        bot.fast = try args["fast"].map { try botDecode(Bool.self, $0, field: "fast") }
        bot.modelPinned = try args["model_pinned"].map { try botDecode(Bool.self, $0, field: "model_pinned") } ?? (bot.model != nil)
        if bot.modelPinned == false {
            guard args["model_pinned"] != nil || args["provider"] == nil && args["reasoning_effort"] == nil && args["fast"] == nil else {
                throw botArgumentError("A provider choice needs a model to pin", field: "model", accepted: "Supply a complete provider/model/reasoning_effort choice, or omit all three to follow Providers.")
            }
            bot.followProviders()
        }
        try await botRouteCheck(bot)
        bot.paused = try args["paused"].map { try botDecode(Bool.self, $0, field: "paused") } ?? false
        bot.dailyTokenCeiling = try args["daily_token_ceiling"].map { try botDecode(Int.self, $0, field: "daily_token_ceiling") }
        bot.eventTrigger = try args["event_trigger"].map(botEventTrigger)
        if bot.eventTrigger != nil, bot.cadence != .manual { throw botTriggerTimingError }
        bot.notificationCondition = try args["notify_condition"].map { try botString($0, field: "notify_condition") }
        return bot
    }

    /// The bot bot_update would write, read from the store and edited in
    /// memory. Shared by dispatch and the pre-approval check; it writes nothing.
    private func botUpdateCandidate(_ args: [String: JSONValue], definitions: BotDefinitionStore, reportShim: Bool = true) async throws -> BotDefinition {
        _ = try botDetails(args)
        let fields = try botObject(args["fields"], field: "fields")
        let edits = fields.filter { $0.value != .null && (["output_format", "schedule", "notify_condition"].contains($0.key) || $0.value != .string("")) }
        guard !edits.isEmpty else { throw botArgumentError("fields must contain at least one setting", field: "fields", accepted: "An object containing at least one setting to change.") }
        var bot = try definitions.get(botReference(args, definitions: definitions, reportShim: reportShim))
        do {
            if let value = edits["name"] { bot.name = try botString(value, field: "name") }
            if let value = edits["brief"] { bot.brief = try botString(value, field: "brief") }
            if let value = edits["personality"] { bot.personality = try botString(value, field: "personality") }
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
            if let value = edits["model"] { bot.model = try botString(value, field: "model"); bot.modelPinned = true }
            if let value = edits["model_pinned"] { bot.modelPinned = try botDecode(Bool.self, value, field: "model_pinned") }
            if let value = edits["reasoning_effort"] { bot.reasoningEffort = try botString(value, field: "reasoning_effort") }
            if let value = edits["fast"] { bot.fast = try botDecode(Bool.self, value, field: "fast") }
            if let value = edits["daily_token_ceiling"] { bot.dailyTokenCeiling = try botDecode(Int.self, value, field: "daily_token_ceiling") }
            if let value = edits["output_format"] { bot.outputFormat = try botDecode(String.self, value, field: "output_format") }
            if let value = edits["budget"] { bot.budget = try botDecode(BotBudget.self, value, field: "budget") }
            if bot.modelPinned == false {
                guard edits["model_pinned"] == .bool(false) || ["provider", "reasoning_effort", "fast"].allSatisfy({ edits[$0] == nil }) else {
                    throw botArgumentError("A provider choice needs a model to pin", field: "model", accepted: "Supply a complete provider/model/reasoning_effort choice, or keep following Providers without per-helper route settings.")
                }
                bot.followProviders()
            }
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
        do { _ = try await BotChatContract.choice(for: bot, dataRoot: dataRoot) }
        catch {
            throw ToolFailureError(String(describing: error), argumentPath: "$",
                accepted: "Follow Providers with model_pinned false, or pin a connected provider/model/reasoning_effort choice from bot_list include_models true.", effects: .none)
        }
    }

    /// shelf_entry save_to: the Save button on a Helpers shelf artifact. Each
    /// inline file is written into the folder under its own name; a file
    /// already there is never replaced. The folder passes the gate write_file
    /// passes: trusted workspace roots, or anywhere under Full Mac file access.
    private func shelfSave(_ artifacts: [BotArtifact], folder: String, surface: String, writeStarted: inout Bool) async throws -> JSONValue {
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
                url = NativeAgentWorkspaceRoot.resolveFileMutationPath(target, dataRoot: dataRoot)
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
            writeStarted = true
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
            row["status"] = .string("saved"); row["byte_size"] = .int(Int64(data.count))
        }
        return .array(rows)
    }

    func impl_standingBots(tool: String, input: [String: JSONValue], surface: String = "chat") async throws -> JSONValue {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let shelf = ShelfStore(dataRoot: dataRoot)
        var writeStarted = false
        do {
            let args = try botArguments(tool: tool, input: input)
            switch tool {
            case "bot_ask":
                let question = try botString(args["question"], field: "question")
                let botID: UUID
                do { botID = try botReference(args, definitions: definitions) }
                catch {
                    let references = botSuppliedReferences(args)
                    if references.count == 1, case .string(let name) = references[0].value {
                        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let contacts = try AgentPeerStore(dataRoot: dataRoot).list().filter {
                            $0.name.caseInsensitiveCompare(name) == .orderedSame
                        }
                        if contacts.count == 1, let contact = contacts.first {
                            return .object(["status": .string("failed"), "reason": .string("agent_contact"),
                                "effects": .string("none"),
                                "detail": .string("\(contact.name) is an agent contact, not a standing helper. Use agent.message to ask it. Nothing was sent."),
                                "next_call": .object(["action": .string("agent.message"), "args": .object([
                                    "agent": .string("peer:" + contact.id), "text": .string(question)])])])
                        }
                    }
                    throw error
                }
                guard allowsCanonicalBodyTools else { throw BotRunnerError.notPermitted }
                guard let standingBotSession else { throw StandingBotsError.invalidValue("Bot chat is unavailable.") }
                _ = try definitions.get(botID)
                writeStarted = true
                let outcome = try await BotRunner(dataRoot: dataRoot, session: standingBotSession).ask(
                    bot: botID, question: question)
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
                case .stopped: wire = "stopped"
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
                try botCheck(candidate, definitions: definitions, input: args)
                let created: BotDefinition
                writeStarted = true
                do { created = try definitions.create(candidate) }
                catch let error as ToolFailureError { throw botTimingError(error, input: args) }
                return try botDefinitionJSON(created,
                    details: botDetails(args), operation: (args["schedule"] ?? .null) == .null
                        && (args["cadence"] ?? .null) == .null && created.eventTrigger == nil ? "created without timing" : "created",
                    currentModel: try? await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model)
            case "bot_update":
                let candidate = try await botUpdateCandidate(args, definitions: definitions)
                do { try botCheck(candidate, definitions: definitions, input: try botObject(args["fields"], field: "fields")) }
                catch let error as ToolFailureError { throw botFieldsError(error) }
                let updated: BotDefinition
                writeStarted = true
                do { updated = try definitions.update(candidate) }
                catch let error as ToolFailureError {
                    throw botFieldsError(botTimingError(error, input: try botObject(args["fields"], field: "fields")))
                }
                return try botDefinitionJSON(updated,
                    details: botDetails(args), operation: "updated",
                    currentModel: try? await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model)
            case "bot_delete":
                let id = try botReference(args, definitions: definitions)
                _ = try definitions.get(id)
                writeStarted = true
                try definitions.delete(id)
                return .object(["status": .string("deleted"), "detail": .string("The session and saved replies are kept.")])
            case "bot_pause":
                let paused = try botDecode(Bool.self, args["paused"], field: "paused")
                let details = try botDetails(args)
                let bot = try definitions.get(botReference(args, definitions: definitions))
                guard bot.cadence != .manual || bot.eventTrigger != nil else {
                    throw botArgumentError("This helper has no schedule to pause or resume. Manual messages and Run once remain available.",
                        field: "id", accepted: "The id of a scheduled helper from bot.list.")
                }
                writeStarted = true
                return try botDefinitionJSON(definitions.pause(bot.id, paused: paused),
                    details: details, operation: paused ? "paused" : "resumed",
                    currentModel: try? await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model)
            case "bot_list":
                let details = try botDetails(args)
                let includeModels = try args["include_models"].map { try botDecode(Bool.self, $0, field: "include_models") } ?? false
                let selected = try args["id"].map { _ in try definitions.get(botReference(args, definitions: definitions)) }
                let currentModel = try? await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model
                // Each helper's last run and last reply are distinct.
                let byBot = (try? shelf.entriesByBot()) ?? [:]
                let iso = ISO8601DateFormatter()
                var result: [String: JSONValue] = ["status": .string("ok"), "bots": .array(try (selected.map { [$0] } ?? definitions.list()).map { bot in
                    guard case .object(var row) = try botDefinitionJSON(bot, details: details, currentModel: currentModel) else {
                        return try botDefinitionJSON(bot, details: details, currentModel: currentModel)
                    }
                    let entries = byBot[bot.id] ?? []
                    if let run = entries.filter({ $0.asked != true }).max(by: { $0.runAt < $1.runAt }) { row["lastRunAt"] = .string(iso.string(from: run.runAt)) }
                    if let reply = entries.filter({ $0.asked == true }).max(by: { $0.runAt < $1.runAt }) { row["lastReplyAt"] = .string(iso.string(from: reply.runAt)) }
                    return .object(row)
                })]
                if includeModels { result["model_choices"] = try await SwiftNativeProviderRouting(dataRoot: dataRoot).botModelChoices() }
                return .object(result)
            case "bot_run_once":
                let bot = try definitions.get(botReference(args, definitions: definitions))
                let question = try args["question"].map { try botString($0, field: "question") }
                guard let standingBotRunEnqueue else {
                    return .object(["status": .string("failed"), "reason": .string("run_queue_unavailable"),
                                    "effects": .string("none"),
                                    "detail": .string("The bot run queue is not connected.")])
                }
                writeStarted = true
                let receipt = try standingBotRunEnqueue(bot.id, question)
                let request = receipt.runID.uuidString
                return .object(["status": .string(receipt.accepted ? "queued" : "joined"), "id": .string(bot.id.uuidString),
                    "requestId": .string(request),
                    "read_with": .object(["action": .string("bot.reply"), "args": .object([
                        "id": .string(request), "bot_id": .string(bot.id.uuidString)])]),
                    "detail": .string("\(receipt.accepted ? "Queued" : "Joined") run \(request). Its result will be saved on the helper's shelf.")])
            case "shelf_entry":
                let markRead = try args["mark_read"].map { try botDecode(Bool.self, $0, field: "mark_read") } ?? true
                let selection = args.filter { !["save_to", "mark_read"].contains($0.key) }
                let savedEntry: ShelfEntry
                if let id = selection["id"] {
                    // The read a run receipt hands back: until the run lands it is running, not missing.
                    let entryID = try botID(id)
                    if let owner = selection["bot_id"], (try? shelf.entry(entryID)) == nil,
                       let presence = try? BotRunQueue(dataRoot: dataRoot).presence(bot: try botID(owner), requestID: entryID),
                       presence == .queued || presence == .running {
                        return .object(["status": .string("running"), "id": .string(entryID.uuidString),
                            "detail": .string("Run \(entryID.uuidString) is \(presence == .queued ? "queued" : "still running") and not on the shelf yet; "
                                + "its result returns to the asking conversation when it lands. This does not start or repeat a run.")])
                    }
                    savedEntry = try shelf.entry(entryID)
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
                    _ = try botString(folder, field: "save_to")
                    saved = try await shelfSave(entry.artifacts ?? [], folder: botString(folder, field: "save_to"), surface: surface,
                                                writeStarted: &writeStarted)
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
                if markRead {
                    writeStarted = true
                    try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: [entry.id])
                }
                return result
            case "shelf_read":
                let bot = botSuppliedReferences(args).isEmpty
                    ? nil : try botReference(args, definitions: definitions)
                let since = try args["since"].map { value in
                    let text = try botString(value, field: "since")
                    // A bare YYYY-MM-DD means local midnight of that day.
                    let day = DateFormatter()
                    day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
                    guard let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) ?? (text.count == 10 ? day.date(from: text) : nil) else {
                        throw StandingBotsError.invalidValue("since must be YYYY-MM-DD (local day) or an ISO 8601 time with time zone")
                    }
                    return date
                }
                let topic = try args["topic"].map { try botDecode(String.self, $0, field: "topic") }
                let cursor = try args["cursor"].map { try botString($0, field: "cursor") }
                let limit = try args["limit"].map { try botDecode(Int.self, $0, field: "limit") } ?? 20
                let offset = try args["offset"].map { try botDecode(Int.self, $0, field: "offset") } ?? 0
                guard offset >= 0, cursor == nil || args["offset"] == nil else {
                    throw botArgumentError("Use a nonnegative offset or a cursor, not both.", field: "offset", accepted: "A nonnegative integer without cursor.")
                }
                let sort = try args["sort"].map { try botString($0, field: "sort") }
                if let sort, !["newest_first", "oldest_first", "oldest_unread"].contains(sort) {
                    throw botArgumentError("Unknown reply sort.", field: "sort", accepted: "newest_first, oldest_first or oldest_unread.")
                }
                guard sort == nil || args["newest_first"] == nil else {
                    throw botArgumentError("Use sort alone to choose reply order.", field: "sort", accepted: "sort without newest_first.")
                }
                let includeRead = try args["include_read"].flatMap { $0 == .null ? nil : $0 }
                    .map { try botDecode(Bool.self, $0, field: "include_read") } ?? (sort != "oldest_unread")
                guard sort != "oldest_unread" || !includeRead else {
                    throw botArgumentError("oldest_unread selects unread replies; include_read true conflicts with it.", field: "include_read", accepted: "false or omitted with oldest_unread.")
                }
                let newestFirst = try args["newest_first"].flatMap { $0 == .null ? nil : $0 }
                    .map { try botDecode(Bool.self, $0, field: "newest_first") } ?? (sort == nil || sort == "newest_first")
                let markRead = try args["mark_read"].flatMap { $0 == .null ? nil : $0 }
                    .map { try botDecode(Bool.self, $0, field: "mark_read") } ?? false
                let page = try shelf.shelfRead(bot: bot, since: since, topic: topic, limit: limit,
                                              cursor: cursor, readerId: includeRead ? nil : Self.standingBotReaderID,
                                              newestFirst: newestFirst, offset: offset)
                // Removed helpers still own their saved replies and names.
                let agentNames = Dictionary(try definitions.list(includeDeleted: true).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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
                    "offset": .int(Int64(offset)),
                    "next_offset": page.nextOffset.map { .int(Int64(markRead && !includeRead ? offset : $0)) } ?? .null,
                    "entries": .array(rows), "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
                    "truncated": .bool(page.truncated || shortenedChange),
                ])
                // Finish every read and response conversion before acknowledging.
                // Lookahead rows, filtered rows and unread earlier gaps stay unread.
                if markRead, !page.rows.isEmpty {
                    writeStarted = true
                    try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: page.rows.map(\.id))
                }
                return result
            default:
                throw StandingBotsError.invalidValue("unknown bots tool")
            }
        } catch let error as BotRunAdmissionError {
            return .object(["status": .string("unavailable"), "reason": .string(error.rawValue),
                "effects": .string(writeStarted ? "unknown" : "none"), "detail": .string(error == .paused
                ? "This bot is paused; resume it to run it."
                : "This bot is already running; its result lands on the shelf when it finishes.")])
        } catch let error as ToolFailureError {
            var result = ChatToolOutcome.failure(error: error, tool: tool)
            if case .object(var fields) = result {
                fields["reason"] = .string("bots_tool_failed")
                fields["failure_code"] = .string("bots_tool_failed")
                fields["detail"] = .string(ChatToolOutcome.errorMessage(error))
                if !writeStarted { fields["effects"] = .string("none") }
                result = .object(fields)
            }
            return result
        } catch let error as StandingBotsError {
            // These definition/queue admissions throw before committing their
            // write. I/O failures remain unknown after an attempted mutation.
            let refusal: Bool
            switch error {
            case .notFound, .alreadyExists, .staleDefinition, .invalidValue, .invalidCursor:
                refusal = !writeStarted || ["bot_create", "bot_update", "bot_pause", "bot_delete", "bot_run_once"].contains(tool)
            case .corruptStore: refusal = !writeStarted
            }
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "effects": .string(refusal ? "none" : "unknown"),
                            "detail": .string(ChatToolOutcome.errorMessage(error))])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "effects": .string(writeStarted ? "unknown" : "none"),
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

private func botObject(_ value: JSONValue?, field: String) throws -> [String: JSONValue] {
    guard case .object(let object) = value else { throw botArgumentError(field + " must be an object", field: field, accepted: "An object.") }
    return object
}

private func botDecode<T: Decodable>(_ type: T.Type, _ value: JSONValue?, field: String) throws -> T {
    var shape = type == Bool.self ? "A boolean." : type == Int.self ? "An integer." : type == String.self ? "A string."
        : type == BotBudget.self ? "An object with tokens: positive integer and seconds: positive finite number."
        : type == BotCadence.self ? "An object with exactly one of manual: {}, interval: {seconds: number}, or cron: {expression: string}. Times are on this Mac's local clock and follow it when it changes zone."
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

/// Every bot-identifying door accepts these spellings.
private let botReferenceKeys = ["id", "bot_id", "bot", "name"]

/// The bot-naming keys actually provided. Strict-provider nulls are absent.
private func botSuppliedReferences(_ args: [String: JSONValue]) -> [(key: String, value: JSONValue)] {
    botReferenceKeys.compactMap { key -> (key: String, value: JSONValue)? in
        guard let value = args[key], value != .null else { return nil }
        return (key: key, value: value)
    }
}

/// The bot named by `id` / `bot_id` / `bot` / `name`: a UUID, or a bot name
/// matched case-insensitively and exactly.
func botReference(_ args: [String: JSONValue], definitions: BotDefinitionStore, reportShim: Bool = true) throws -> UUID {
    let supplied = botSuppliedReferences(args)
    var corrected = botReferenceKeys.filter { args[$0] != nil }.count != supplied.count
    defer {
        if reportShim, corrected {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T19"), "site": .string("SwiftToolDispatcher+StandingBots.swift:botReference")]))
        }
    }
    let shelf = try definitions.list()
    func refuse(_ lead: String) -> ToolFailureError {
        let listed = shelf.isEmpty
            ? "There are no helpers yet — make one with bot.create."
            : "Bots: " + shelf.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: "; ")
        return botArgumentError(lead + " Use id: a helper UUID from bot.list, or its exact name. " + listed,
            field: "id", accepted: "A helper UUID or exact name from bot.list.")
    }
    guard !supplied.isEmpty else { throw refuse("No bot named.") }
    let resolved = try supplied.map { reference -> (id: UUID, shim: Bool) in
        let text = try botString(reference.value, field: reference.key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw refuse("\(reference.key) is blank.") }
        if let id = UUID(uuidString: text) { return (id, reference.key != "id") }
        let exact = shelf.filter { $0.name.lowercased() == text.lowercased() }
        if exact.count == 1 { return (exact[0].id, true) }
        if exact.count > 1 { throw refuse("More than one bot is called \"\(text)\"; use its ID.") }
        throw refuse("No bot matches \"\(text)\".")
    }
    let ids = resolved.map(\.id)
    guard Set(ids).count == 1 else {
        throw refuse("Conflicting bot fields: " + supplied.map(\.key).joined(separator: ", ") + ". Pass id alone, for example id: \"\(ids[0])\".")
    }
    corrected = corrected || supplied.count > 1 || resolved.contains { $0.shim }
    return ids[0]
}

/// The Bots editor's "On an event", checked the way the editor checks it.
private func botEventTrigger(_ value: JSONValue?) throws -> BotEventTrigger {
    let object = try botObject(value, field: "event_trigger").filter { $0.value != .null }
    let raw = try botString(object["source"], field: "event_trigger.source")
    guard let source = BotEventSource(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
        throw botArgumentError("event_trigger.source must be slack", field: "event_trigger.source", accepted: "slack.")
    }
    let filter = try botString(object["filter"], field: "event_trigger.filter").trimmingCharacters(in: .whitespacesAndNewlines)
    // Slack delivers a channel ID, never a name, so a name would never match.
    if !BotEventTrigger.isChannelID(filter) {
        throw botArgumentError("A Slack trigger needs the channel ID, such as C0123ABCD, not its name. In Slack, open the channel, choose View channel details, and copy the ID at the bottom.", field: "event_trigger.filter", accepted: "A Slack channel ID such as C0123ABCD.")
    }
    let keyword = try object["keyword"].map { try botDecode(String.self, $0, field: "event_trigger.keyword") }
    return BotEventTrigger(source: source, filter: filter.uppercased(), keyword: keyword)
}

private var botTriggerTimingError: ToolFailureError { botArgumentError(
    "An event-woken helper keeps no schedule: the event is what runs it. Drop schedule and cadence, or use schedule manual.",
    field: "event_trigger", accepted: "event_trigger with no schedule, or with schedule manual.") }

/// Both pre-approval and persistence call this adapter; cadence validity and
/// the operator's minimum interval still belong to BotDefinitionStore.
private func botRequestedCadence(_ args: [String: JSONValue]) throws -> BotCadence? {
    let args = args.filter { $0.value != .null }
    guard args["schedule"] != nil else {
        return try args["cadence"].map { try botDecode(BotCadence.self, $0, field: "cadence") }
    }
    guard args["cadence"] == nil else {
        throw botArgumentError("Use schedule or cadence, not both", field: "schedule", accepted: "Supply schedule or cadence, not both.")
    }
    do {
        return try StandingBotSchedule.parse(botString(args["schedule"], field: "schedule"))
    } catch StandingBotsError.invalidValue(let message) {
        throw ToolFailureError(message, argumentPath: "$", accepted: "schedule: manual; every N minutes or hours; daily at HH:mm; weekdays at HH:mm; weekly on DAY at HH:mm. Clock: 00:00-23:59 on this Mac's local clock.", effects: .none)
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

private func botDefinitionJSON(_ bot: BotDefinition, details: Bool = false, operation: String? = nil, currentModel: String? = nil) throws -> JSONValue {
    guard case .object(var fields) = try botJSON(bot) else { throw StandingBotsError.invalidValue("bot") }
    if !details {
        let visible: Set<String> = ["id", "name", "personality", "brief", "provider", "model", "modelPinned", "reasoningEffort", "fast",
                                   "cadence", "paused", "offReason", "budget", "outputFormat", "eventTrigger", "notificationCondition"]
        fields = fields.filter { visible.contains($0.key) }
    }
    fields["status"] = .string("ok")
    fields["model_selection"] = .string(bot.modelSelection(currentModel: currentModel))
    fields["session_id"] = .string(bot.sessionID)
    fields["daily_token_ceiling"] = bot.dailyTokenCeiling.map { .int(Int64($0)) } ?? .string("none")
    fields["schedule"] = .string(StandingBotSchedule.describe(bot.cadence))
    fields["output_format"] = .string(bot.outputFormat ?? "")
    if case .cron = bot.cadence {
        fields["mac_timezone"] = .string(TimeZone.current.identifier)
        fields["timezone_detail"] = .string("Follows the Mac: \(TimeZone.current.identifier).")
    }
    fields["scheduler_status"] = .string(bot.paused ? "paused" : bot.eventTrigger != nil ? "on_event" : bot.cadence == .manual ? "manual" : "scheduled")
    let reference = JSONValue.string(bot.name)
    // Each is her app call: these tools are app actions now.
    var actions: [String: JSONValue] = [
        "talk": .object(["tool": .string("agent_message"),
            "input": .object(["agent": reference, "text": .string("<your message>")])]),
        "open_reply": .object(["tool": .string("agent_read"), "input": .object(["agent": reference])]),
        "run_once": .object(["tool": .string("bot_run_once"), "input": .object(["id": reference])]),
    ]
    if bot.cadence != .manual || bot.eventTrigger != nil {
        actions[bot.paused ? "resume" : "pause"] = .object(["tool": .string("bot_pause"),
            "input": .object(["id": reference, "paused": .bool(!bot.paused)])])
    }
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
