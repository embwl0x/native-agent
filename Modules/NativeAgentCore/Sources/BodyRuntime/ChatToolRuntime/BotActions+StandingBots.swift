import MacNerves
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import DeskCore
import SenseCore
// Blueprint: | `BotActions+StandingBots.swift` | `SwiftToolDispatcher` `standingBotApprovalReason` `standingBotsArgumentRefusal` `impl_standingBots` (stages `standingBotAsk`, `standingBotList`, `standingBotShelfEntry`, `standingBotShelfRead`; `BotCallProgress` says whether a write began) |

enum StandingBotCall: Sendable {
    case create(BotCreateArgs)
    case update(BotUpdateArgs)
    case pause(BotPauseArgs)
    case delete(BotDeleteArgs)
    case list(BotListArgs)
    case runOnce(BotRunOnceArgs)
    case ask(BotAskArgs)
    case shelfRead(ShelfReadArgs)
    case shelfEntry(ShelfEntryArgs)
}

extension SwiftToolDispatcher {
    static func standingBotApprovalReason(input: BotDeleteArgs, dataRoot: URL) -> String {
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        guard let id = try? botReference(input.id, definitions: definitions, dataRoot: dataRoot),
              let bot = try? definitions.get(id) else { return "Delete this bot? Its saved notes stay." }
        return "Delete the bot \(bot.name)? Its saved notes stay."
    }

    /// Shared across chat surfaces, separate from every UI reader. Sparse IDs, never the page token, are persisted as the agent's acknowledgement.
    static let standingBotReaderID = "agent"

    /// The same builders validate shape, cadence and route before approval and again before writing.
    func standingBotsArgumentRefusal(tool: String, input: StandingBotCall) async -> JSONValue? {
        guard tool == "bot_create" || tool == "bot_update" else { return nil }
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        do {
            switch input {
            case .create(let args):
                let candidate = try await botCreateCandidate(args)
                try botCheck(candidate.bot, definitions: definitions, schedule: args.settings.schedule)
            case .update(let args):
                let candidate = try await botUpdateCandidate(args, definitions: definitions)
                do { try botCheck(candidate.bot, definitions: definitions, schedule: args.settings.schedule) }
                catch let error as ToolFailureError { throw botFieldsError(error) }
            default: return nil
            }
            return nil
        } catch let error as BotChatContract.FollowingSettingsRefusal {
            return botFollowingRefusal(error, tool: tool, code: "invalid_arguments")
        } catch {
            var result = ChatToolOutcome.failure(error: error, tool: tool)
            if case .object(var fields) = result {
                // An owner's own cause (model_not_offered) stands; an uncoded refusal is an argument refusal.
                let code = (error as? ToolFailureError)?.code ?? "invalid_arguments"
                fields["reason"] = .string(code)
                fields["failure_code"] = .string(code)
                fields["detail"] = .string(ChatToolOutcome.errorMessage(error))
                fields["effects"] = .string("none")
                result = ChatToolOutcome.normalizedFailure(.object(fields), tool: tool)
            }
            return result
        }
    }

    /// Share the write-free create builder with pre-approval so preview admits the same shape.
    private func botCreateCandidate(_ args: BotCreateArgs) async throws -> (bot: BotDefinition, notes: [String]) {
        let settings = args.settings
        var bot = BotDefinition(name: try botString(settings.name, field: "name"),
                                brief: try botString(settings.brief, field: "brief"),
                                cadence: try botRequestedCadence(settings) ?? .manual,
                                budget: settings.budget?.value
                                    ?? BotBudget(tokens: BotRunLimits.maximumTokens))
        bot.personality = try settings.personality.map { try botString($0, field: "personality") }
        bot.provider = try settings.provider.map { try botString($0, field: "provider") }
        bot.model = try settings.model.map { try botString($0, field: "model") }
        bot.reasoningEffort = try settings.reasoningEffort.map { try botString($0, field: "reasoning_effort") }
        bot.fast = settings.fast
        bot.modelPinned = settings.modelPinned ?? (bot.model != nil)
        let notes = try await BotChatContract.followingSettings(for: bot, fields: settings.submittedModelSettings, dataRoot: dataRoot)
        if bot.modelPinned != true { bot.followProviders() }
        try await botRouteCheck(bot)
        bot.paused = args.paused ?? false
        bot.dailyTokenCeiling = settings.dailyTokenCeiling
        bot.eventTrigger = try settings.eventTrigger.map(botEventTrigger)
        if bot.eventTrigger != nil, bot.cadence != .manual { throw botTriggerTimingError }
        bot.notificationCondition = try settings.notifyCondition.flatMap { $0.isEmpty ? nil : $0 }.map { try botString($0, field: "notify_condition") }
        return (bot, notes)
    }

    /// Share the write-free update builder with pre-approval so preview admits the same edit.
    private func botUpdateCandidate(_ args: BotUpdateArgs, definitions: BotDefinitionStore) async throws -> (
        bot: BotDefinition, notes: [String]) {
        let edits = args.settings
        guard edits.hasEdit else { throw botArgumentError("fields must contain at least one setting", field: "fields",
            accepted: "An object containing at least one setting to change.") }
        var bot = try definitions.get(botReference(args.id, definitions: definitions, dataRoot: dataRoot))
        let saved = bot
        let notes: [String]
        do {
            if let value = edits.name { bot.name = try botString(value, field: "name") }
            if let value = edits.brief { bot.brief = try botString(value, field: "brief") }
            if let value = edits.personality { bot.personality = try botString(value, field: "personality") }
            // One "When" choice, as in the Bots editor: a schedule replaces an event trigger, and an event trigger replaces the schedule.
            let timing = try botRequestedCadence(edits)
            if let timing { bot.cadence = timing; bot.eventTrigger = nil }
            if let value = edits.eventTrigger {
                guard timing == nil || timing == .manual else { throw botTriggerTimingError }
                bot.eventTrigger = try botEventTrigger(value)
                bot.cadence = .manual
            }
            if let value = edits.notifyCondition {
                let text = value
                bot.notificationCondition = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
            if let value = edits.provider { bot.provider = try botString(value, field: "provider") }
            if let value = edits.model { bot.model = try botString(value, field: "model"); bot.modelPinned = true }
            if let value = edits.modelPinned { bot.modelPinned = value }
            if let value = edits.reasoningEffort { bot.reasoningEffort = try botString(value, field: "reasoning_effort") }
            if let value = edits.fast { bot.fast = value }
            if let value = edits.dailyTokenCeiling { bot.dailyTokenCeiling = value }
            if let value = edits.budget { bot.budget = value.value }
            notes = try await BotChatContract.followingSettings(for: bot, fields: edits.submittedModelSettings, dataRoot: dataRoot)
            if bot.modelPinned != true { bot.followProviders() }
            try await botRouteCheck(bot, held: saved.modelPinned == true && saved.provider == bot.provider ? saved.model : nil)
        } catch let error as ToolFailureError {
            throw botFieldsError(error)
        }
        return (bot, notes)
    }

    private func botRouteCheck(_ bot: BotDefinition, held: String? = nil) async throws {
        let accepted = """
            Follow Providers with model_pinned false, or pin a connected provider/model/reasoning_effort choice from bot_list \
            include_models true.
            """
        // A pinned model's own causes (account, model list, the model) come first, each named at its argument with its own code.
        if bot.modelPinned == true, let provider = bot.provider, let model = bot.model,
           let refusal = try await SwiftNativeProviderRouting(dataRoot: dataRoot).botModelRefusal(provider: provider, model: model, held: held) {
            throw ToolFailureError(refusal.message, argumentPath: refusal.field.map { "$." + $0 }, accepted: accepted, effects: .none,
                                   code: refusal.code)
        }
        do { _ = try await BotChatContract.choice(for: bot, dataRoot: dataRoot) }
        catch { throw ToolFailureError(String(describing: error), argumentPath: "$", accepted: accepted, effects: .none) }
    }

    /// Shelf exports never replace existing files and share write_file’s workspace and Full Mac gates.
    private func shelfSave(turn: Turn, invocation: ChatToolInvocation, _ artifacts: [BotArtifact], folder: String, surface: String,
        writeStarted: inout Bool) async throws -> (
        receipt: JSONValue, needs: [JSONValue]) {
        let anywhere = try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed
        var rows: [JSONValue] = []
        var needs: [JSONValue] = []
        for (index, artifact) in artifacts.enumerated() {
            let name = URL(fileURLWithPath: artifact.name).lastPathComponent
            var row: [String: JSONValue] = ["index": .int(Int64(index)), "name": .string(artifact.name)]
            defer { rows.append(.object(row)) }
            do {
                guard artifact.path.isEmpty else {
                    // The shelf owns this reference; export did not read or verify its bytes.
                    row["status"] = .string("referenced"); row["path"] = .string(artifact.path)
                    continue
                }
                guard let encoded = artifact.base64, let data = Data(base64Encoded: encoded),
                      !["", ".", "..", "/"].contains(name) else {
                    row["status"] = .string("unavailable"); row["detail"] = .string("No saved file content.")
                    continue
                }
                let target = (folder as NSString).appendingPathComponent(name)
                row["requestedPath"] = .string(target)
                let url: URL
                if anywhere {
                    url = NativeAgentWorkspaceRoot.resolveFileMutationPath(target, dataRoot: dataRoot)
                } else {
                    do { url = try await resolveTrustedFilePath(turn: turn, target, write: true) }
                    catch {
                        if let need = fileOpsNeedEnvelope(invocation: invocation, tool: "shelf_entry", mode: .write, path: target, error: error) {
                            needs.append(need)
                            if let cardID = need.objectValue?["card_id"] { row["card_id"] = cardID }
                        }
                        throw error
                    }
                }
                // The sensitive-subtree fence every file tool keeps, Full Mac or not.
                guard !connectorPathIsSensitiveData(url.resolvingSymlinksInPath(), dataRoot: dataRoot, turn: turn) else {
                    throw StandingBotsError.invalidValue("""
                        This item's save_to is inside the app's protected data (credentials, pairing, Trust policy). Choose a folder outside it, \
                        such as one in the workspace.
                        """)
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
            } catch {
                row["status"] = .string("failed")
                row["error"] = .string(error.localizedDescription)
            }
        }
        let incomplete = rows.contains { row in
            guard case .object(let fields) = row else { return true }
            return fields["status"] != .string("saved") && fields["status"] != .string("referenced")
        }
        return (.object(["status": .string(incomplete ? "partial" : "ok"), "files": .array(rows)]), needs)
    }

    func impl_standingBots(_ context: ActionContext, _ input: StandingBotCall) async throws -> JSONValue {
        let (turn, invocation, tool, surface) = (context.turn, context.invocation, context.tool, context.surface)
        let definitions = BotDefinitionStore(dataRoot: dataRoot)
        let shelf = ShelfStore(dataRoot: dataRoot)
        let progress = BotCallProgress()
        do {
            switch input {
            case .ask(let args):
                return try await standingBotAsk(turn: turn, invocation: invocation, args: args, definitions: definitions, progress: progress)
            case .create(let args):
                recordBotCadenceShim(args.settings)
                let candidate = try await botCreateCandidate(args)
                try botCheck(candidate.bot, definitions: definitions, schedule: args.settings.schedule)
                let currentModel: String?
                if candidate.bot.modelPinned == true { currentModel = nil }
                else { currentModel = try await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model }
                let created: BotDefinition
                progress.writeStarted = true
                do { created = try definitions.create(candidate.bot) }
                catch let error as ToolFailureError { throw botTimingError(error, schedule: args.settings.schedule) }
                return try botDefinitionJSON(created,
                    details: args.details ?? false, operation: args.settings.schedule == nil
                        && args.settings.cadence == nil && created.eventTrigger == nil ? "created without timing" : "created",
                    currentModel: currentModel,
                    notes: candidate.notes)
            case .update(let args):
                recordBotCadenceShim(args.settings)
                let candidate = try await botUpdateCandidate(args, definitions: definitions)
                do { try botCheck(candidate.bot, definitions: definitions, schedule: args.settings.schedule) }
                catch let error as ToolFailureError { throw botFieldsError(error) }
                let currentModel: String?
                if candidate.bot.modelPinned == true { currentModel = nil }
                else { currentModel = try await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model }
                let updated: BotDefinition
                progress.writeStarted = true
                do { updated = try definitions.update(candidate.bot) }
                catch let error as ToolFailureError {
                    throw botFieldsError(botTimingError(error, schedule: args.settings.schedule))
                }
                return try botDefinitionJSON(updated,
                    details: args.details ?? false, operation: "updated",
                    currentModel: currentModel,
                    notes: candidate.notes)
            case .delete(let args):
                let id = try botReference(args.id, definitions: definitions, dataRoot: dataRoot)
                _ = try definitions.get(id)
                progress.writeStarted = true
                try definitions.delete(id)
                return .object(["status": .string("deleted"), "detail": .string("The session and saved replies are kept.")])
            case .pause(let args):
                let paused = args.paused
                let details = args.details ?? false
                let bot = try definitions.get(botReference(args.id, definitions: definitions, dataRoot: dataRoot))
                guard bot.cadence != .manual || bot.eventTrigger != nil else {
                    throw botArgumentError("This helper has no schedule to pause or resume. Manual messages and Run once remain available.",
                        field: "id", accepted: "The id of a scheduled helper from bot.list.")
                }
                let currentModel: String?
                if bot.modelPinned == true { currentModel = nil }
                else { currentModel = try await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model }
                progress.writeStarted = true
                return try botDefinitionJSON(definitions.pause(bot.id, paused: paused),
                    details: details, operation: paused ? "paused" : "resumed",
                    currentModel: currentModel)
            case .list(let args):
                return try await standingBotList(args: args, definitions: definitions, shelf: shelf)
            case .runOnce(let args):
                let bot = try definitions.get(botReference(args.id, definitions: definitions, dataRoot: dataRoot))
                let question = try args.question.map { try botString($0, field: "question") }
                guard let standingBotRunEnqueue else {
                    return .object(["status": .string("failed"), "reason": .string("run_queue_unavailable"),
                                    "effects": .string("none"),
                                    "detail": .string("The bot run queue is not connected.")])
                }
                progress.writeStarted = true
                let receipt = try standingBotRunEnqueue(bot.id, question, turn, invocation.botAncestry)
                let request = receipt.runID.uuidString
                return .object(["status": .string(receipt.accepted ? "queued" : "joined"), "id": .string(bot.id.uuidString),
                    "requestId": .string(request),
                    "read_with": .object(["action": .string("bot.reply"), "args": .object([
                        "id": .string(request), "bot_id": .string(bot.id.uuidString)])]),
                    "detail": .string("\(receipt.accepted ? "Queued" : "Joined") run \(request). Its result will be saved on the helper's shelf.")])
            case .shelfEntry(let args):
                return try await standingBotShelfEntry(turn: turn, invocation: invocation, args: args, definitions: definitions, shelf: shelf,
                    surface: surface, progress: progress)
            case .shelfRead(let args):
                return try standingBotShelfRead(args: args, definitions: definitions, shelf: shelf, progress: progress)
            }
        } catch let error as BotRunAdmissionError {
            return .object(["status": .string("unavailable"), "reason": .string(error.rawValue),
                "effects": .string(progress.writeStarted ? "unknown" : "none"), "detail": .string(error == .paused
                ? "This bot is paused; resume it to run it."
                : "This bot is already running; its result lands on the shelf when it finishes.")])
        } catch let error as BotChatContract.FollowingSettingsRefusal {
            return botFollowingRefusal(error, tool: tool, code: "bots_tool_failed")
        } catch let error as ToolFailureError {
            var result = ChatToolOutcome.failure(error: error, tool: tool)
            if case .object(var fields) = result {
                // The owner's own cause stands, as on the pre-approval path; only an uncoded failure is the tool's.
                let code = error.code ?? "bots_tool_failed"
                fields["reason"] = .string(code)
                fields["failure_code"] = .string(code)
                fields["detail"] = .string(ChatToolOutcome.errorMessage(error))
                if !progress.writeStarted { fields["effects"] = .string("none") }
                result = .object(fields)
            }
            return result
        } catch let error as StandingBotsError {
            // These definition/queue admissions throw before committing their write. I/O failures remain unknown after an attempted mutation.
            let refusal: Bool
            switch error {
            case .notFound, .alreadyExists, .staleDefinition, .invalidValue, .invalidCursor:
                refusal = !progress.writeStarted || ["bot_create", "bot_update", "bot_pause", "bot_delete", "bot_run_once"].contains(tool)
            case .corruptStore: refusal = !progress.writeStarted
            }
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "effects": .string(refusal ? "none" : "unknown"),
                            "detail": .string(ChatToolOutcome.errorMessage(error))])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("bots_tool_failed"),
                            "effects": .string(progress.writeStarted ? "unknown" : "none"),
                            "detail": .string(ChatToolOutcome.errorMessage(error))])
        }
    }

    /// Asks a helper in its own chat and answers with its reply and status, its saved return address and bounded artifact references.
    private func standingBotAsk(turn: Turn, invocation: ChatToolInvocation, args: BotAskArgs, definitions: BotDefinitionStore,
        progress: BotCallProgress) async throws -> JSONValue {
        let question = try botString(args.question, field: "question")
        let botID = try botReference(args.id, definitions: definitions, dataRoot: dataRoot, question: question)
        guard allowsCanonicalBodyTools else { throw BotRunnerError.notPermitted }
        guard let standingBotRunner else { throw StandingBotsError.invalidValue("Bot chat is unavailable.") }
        _ = try definitions.get(botID)
        progress.writeStarted = true
        let outcome = try await standingBotRunner.ask(
            bot: botID, question: question, parent: turn, scope: .init(ancestry: invocation.botAncestry))
        // Approved replay needs an explicit status to distinguish failed asks from success; retain any partial answer.
        let status = outcome.runtimeStatus
        // Use the trace’s verdict vocabulary: an approval hold is neither failure nor progress.
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
            // Retain the runner’s saved return address so retrieving output needs no repeated run or shelf search.
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
        // Bound artifact references and leave inline bytes in storage so large runs cannot flood the answer.
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
        result["shelf_entry"] = .object([
            "tool": .string("shelf_entry"), "id": .string(outcome.id.uuidString),
        ])
        return .object(result)
    }

    /// Every helper, or the one named, with its last run and last reply; the model choices when asked.
    private func standingBotList(args: BotListArgs, definitions: BotDefinitionStore, shelf: ShelfStore) async throws -> JSONValue {
        let details = args.details ?? false
        let includeModels = args.includeModels ?? false
        let selected = try args.id.map { try definitions.get(botReference($0, definitions: definitions, dataRoot: dataRoot)) }
        let currentModel = try await SwiftNativeProviderRouting(dataRoot: dataRoot).modelForSurface("chat").model
        // Each helper's last run and last reply are distinct.
        let byBot = try shelf.entriesByBot()
        let iso = ISO8601DateFormatter()
        var result: [String: JSONValue] = ["status": .string("ok"), "bots": .array(try (selected.map { [$0] } ?? definitions.list()).map { bot in
            guard case .object(var row) = try botDefinitionJSON(bot, details: details, currentModel: currentModel) else {
                return try botDefinitionJSON(bot, details: details, currentModel: currentModel)
            }
            let entries = byBot[bot.id] ?? []
            if let run = entries.filter({ $0.asked != true }).max(by: { $0.runAt < $1.runAt }) { row["lastRunAt"] = .string(iso.string(
                from: run.runAt)) }
            if let reply = entries.filter({ $0.asked == true }).max(by: { $0.runAt < $1.runAt }) { row["lastReplyAt"] = .string(iso
                .string(from: reply.runAt)) }
            return .object(row)
        })]
        if includeModels { result["model_choices"] = try await SwiftNativeProviderRouting(dataRoot: dataRoot).botModelChoices() }
        return .object(result)
    }

    /// One shelf entry: a landed run, a run still on its way, or the helper's latest reply; its files are saved when asked and it is marked
    /// read after the response is built.
    private func standingBotShelfEntry(turn: Turn, invocation: ChatToolInvocation, args: ShelfEntryArgs, definitions: BotDefinitionStore,
        shelf: ShelfStore, surface: String, progress: BotCallProgress) async throws -> JSONValue {
        let markRead = args.markRead ?? true
        let savedEntry: ShelfEntry
        if let id = args.id {
            // The read a run receipt hands back: until the run lands it is running, not missing.
            let entryID = try botID(id)
            let landed: ShelfEntry?
            do { landed = try shelf.entry(entryID) }
            catch StandingBotsError.notFound { landed = nil }
            if let owner = args.botID, landed == nil {
                let presence = try BotRunQueue(dataRoot: dataRoot).presence(bot: try botID(owner), requestID: entryID)
                switch presence {
                case .queued, .running:
                    return .object(["status": .string("running"), "id": .string(entryID.uuidString),
                        "detail": .string("Run \(entryID.uuidString) is \(presence == .queued ? "queued" : "still running") and not on the shelf yet; "
                            + "its result returns to the asking conversation when it lands. This does not start or repeat a run.")])
                case .absent:
                    if let detail = try BotRunQueue(dataRoot: dataRoot).refusal(bot: botID(owner), requestID: entryID) {
                        return .object(["status": .string("refused"), "effects": .string("none"),
                            "id": .string(entryID.uuidString), "terminal": .bool(true), "detail": .string(detail)])
                    }
                }
            }
            guard let landed else { throw StandingBotsError.notFound(entryID) }
            savedEntry = landed
            if let expected = args.botID, savedEntry.botId != (try botID(expected)) {
                throw StandingBotsError.invalidValue(
                    "This shelf entry belongs to a different bot. Use the exact message_id returned by the selected bot.")
            }
        } else {
            let selected = try definitions.get(botReference(args.botID, definitions: definitions, dataRoot: dataRoot))
            guard let latest = try shelf.entriesByBot()[selected.id]?.last else {
                return .object(["status": .string("empty"), "agent_name": .string(selected.name),
                    "session_id": .string(selected.sessionID),
                    "detail": .string("No settled reply yet. This does not start or repeat a run.")])
            }
            savedEntry = latest
        }
        let entry = savedEntry
        // Encode before exporting: a projection error cannot discard committed files.
        var result = try botJSON(entry)
        var saved: JSONValue?
        var needs: [JSONValue] = []
        if let folder = args.saveTo {
            let exported = try await shelfSave(turn: turn, invocation: invocation, entry.artifacts ?? [], folder: botString(folder,
                        field: "save_to"), surface: surface, writeStarted: &progress.writeStarted)
            saved = exported.receipt
            needs = exported.needs
        }
        if case .object(var fields) = result {
            fields["status"] = saved?.objectValue?["status"] ?? .string("ok")
            fields["answer"] = .string(entry.actualReply)
            fields["run_status"] = .string(entry.runtimeStatus.rawValue)
            fields["status_detail"] = entry.statusDetail.map(JSONValue.string) ?? .null
            if let name = try? definitions.get(entry.botId).name {
                fields["agent_name"] = .string(name)
            }
            if let saved { fields["saved"] = saved }
            if !needs.isEmpty { fields[InlineInteractionWire.needsKey] = .array(needs) }
            result = .object(fields)
        }
        if markRead {
            progress.writeStarted = true
            do {
                try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: [entry.id])
            } catch {
                guard case .object(var fields) = result else { throw error }
                fields["status"] = .string("partial")
                fields["acknowledgeError"] = .string(error.localizedDescription)
                return .object(fields)
            }
        }
        return result
    }

    /// A page of a helper's saved or unread replies; they are acknowledged only after the whole response is built.
    private func standingBotShelfRead(args: ShelfReadArgs, definitions: BotDefinitionStore, shelf: ShelfStore,
        progress: BotCallProgress) throws -> JSONValue {
        let bot = try args.id.map { try botReference($0, definitions: definitions, dataRoot: dataRoot) }
        let since = try args.since.map { value in
            let text = try botString(value, field: "since")
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
            guard let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) ?? (text.count == 10 ? day.date(from: text) : nil) else {
                throw StandingBotsError.invalidValue("since must be YYYY-MM-DD (local day) or an ISO 8601 time with time zone")
            }
            return date
        }
        let topic = args.topic
        let cursor = try args.cursor.map { try botString($0, field: "cursor") }
        let limit = args.limit ?? 20
        let offset = args.offset ?? 0
        guard offset >= 0, cursor == nil || args.offset == nil else {
            throw botArgumentError("Use a nonnegative offset or a cursor, not both.", field: "offset",
                accepted: "A nonnegative integer without cursor.")
        }
        let sort = try args.sort.map { try botString($0, field: "sort") }
        if let sort, !["newest_first", "oldest_first", "oldest_unread"].contains(sort) {
            throw botArgumentError("Unknown reply sort.", field: "sort", accepted: "newest_first, oldest_first or oldest_unread.")
        }
        let includeRead = args.includeRead ?? (sort != "oldest_unread")
        guard sort != "oldest_unread" || !includeRead else {
            throw botArgumentError("oldest_unread selects unread replies; include_read true conflicts with it.", field: "include_read",
                accepted: "false or omitted with oldest_unread.")
        }
        let newestFirst = sort == nil || sort == "newest_first"
        let markRead = args.markRead ?? false
        let page = try shelf.shelfRead(bot: bot, since: since, topic: topic, limit: limit,
                                      cursor: cursor, readerId: includeRead ? nil : Self.standingBotReaderID,
                                      newestFirst: newestFirst, offset: offset)
        // Saved replies and names outlive their helper’s definition.
        let agentNames = Dictionary(try definitions.list(includeDeleted: true).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var shortenedChange = false
        let reconciled = try page.rows.map { try shelf.entry($0.id) }
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
            "has_more": .bool(page.nextOffset != nil),
            "partial": .bool(shortenedChange || page.rows.contains(where: \.headlineTruncated)),
        ])
        // Finish every read and response conversion before acknowledging. Lookahead rows, filtered rows and unread earlier gaps stay unread.
        if markRead, !page.rows.isEmpty {
            progress.writeStarted = true
            try shelf.acknowledge(readerId: Self.standingBotReaderID, entryIds: page.rows.map(\.id))
        }
        return result
    }
}

private func botArgumentError(_ message: String, field: String, accepted: String) -> ToolFailureError {
    ToolFailureError(message, argumentPath: "$." + field, accepted: accepted, effects: .none)
}

private func botFollowingRefusal(_ error: BotChatContract.FollowingSettingsRefusal, tool: String, code: String) -> JSONValue {
    let prefix = tool == "bot_update" ? "$.fields." : "$."
    let problems: [JSONValue] = error.problems.map {
        .object(["argument_path": .string(prefix + $0.field), "detail": .string($0.message)])
    }
    return ChatToolOutcome.normalizedFailure(.object([
        "status": .string("refused"), "reason": .string(code), "failure_code": .string(code),
        "effects": .string("none"), "detail": .string(error.localizedDescription),
        "argument_path": error.problems.first.map { .string(prefix + $0.field) } ?? .null,
        "argument_errors": .array(problems),
        "accepted": .string("""
            Omit per-helper settings to follow Providers, submit the inherited value as a no-op, or pin a model (model_pinned:true, model, \
            provider) to set them.
            """)
    ]), tool: tool)
}

private func botFieldsError(_ error: ToolFailureError) -> ToolFailureError {
    // Only the path moves under fields; the owner's code, status and levers stay its own.
    ToolFailureError(error.message, argumentPath: error.argumentPath.map { "$.fields" + $0.dropFirst() },
        accepted: error.accepted, effects: error.effects, owner: error.owner, nextCall: error.nextCall, tap: error.tap,
        personDecides: error.personDecides, code: error.code, status: error.status, instruction: error.instruction, recovery: error.recovery)
}

private func recordBotCadenceShim(_ settings: BotSettingsFields) {
    if settings.cadence?.omittedNullBranches.isEmpty == false {
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T21"),
            "site": .string("BotActions+StandingBots.swift:botCadence")]), turn: nil)
    }
}

private func botTimingError(_ error: ToolFailureError, schedule: String?) -> ToolFailureError {
    if schedule != nil, error.argumentPath?.hasPrefix("$.cadence") == true {
        return botArgumentError(error.message, field: "schedule",
            accepted: "A schedule string: every N minutes or every N hours, with positive integer N and an interval meeting the reported minimum.")
    }
    return error
}

private func botCheck(_ candidate: BotDefinition, definitions: BotDefinitionStore, schedule: String?) throws {
    do { try definitions.check(candidate) }
    catch let error as ToolFailureError {
        throw botTimingError(error, schedule: schedule)
    }
}

private func botString(_ value: String?, field: String) throws -> String {
    guard let text = value else { throw botArgumentError("missing " + field, field: field, accepted: "A string.") }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw botArgumentError("empty " + field, field: field,
        accepted: "A nonblank string.") }
    return text
}

private func botID(_ value: String?) throws -> UUID {
    guard let id = UUID(uuidString: try botString(value, field: "id")) else { throw StandingBotsError.invalidValue("id must be a UUID") }
    return id
}

/// The one helper resolver: bot.* and the Helpers page item. A helper is shown as its UUID (any case), its contact bot:<UUID>,
/// its session bot-<uuid> or its name; each names it here. Only bot_ask passes its validated question so a contact remedy preserves it;
/// other callers inspect the contact, including bot_run_once with a question.
func botReference(_ reference: String?, definitions: BotDefinitionStore, dataRoot: URL, question: String? = nil) throws -> UUID {
    let text = try botString(reference, field: "id").trimmingCharacters(in: .whitespacesAndNewlines)
    let id = UUID(uuidString: text.hasPrefix("bot:") ? String(text.dropFirst(4)) : text) ?? BotDefinition.id(forSession: text)
    if let id {
        do { _ = try definitions.get(id); return id }
        catch StandingBotsError.notFound { }
    }
    let matches: [BotDefinition] = if id == nil {
        try definitions.list().filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
    } else { [] }
    if matches.count == 1, let helper = matches.first { return helper.id }
    if matches.isEmpty {
        let contacts = try AgentPeerStore(dataRoot: dataRoot).references(named: text)
        if contacts.count == 1, let contact = contacts.first {
            let action: String
            let guidance: String
            let recovery: ToolFailureError.Recovery
            var contactArgs: [String: JSONValue] = ["agent": .string(contact)]
            if let question {
                action = "agent.message"
                contactArgs["text"] = .string(question)
                guidance = "Use agent.message to ask it."
                recovery = .correctArguments
            } else {
                action = "agent.read"
                guidance = "Read its conversation with agent.read."
                recovery = .inspect
            }
            throw ToolFailureError("\(text) is an agent contact, not a helper. \(guidance) Nothing ran.",
                argumentPath: "$.id", accepted: "A helper UUID or exact name from bot.list.", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string(action), "args": .object(contactArgs)]),
                recovery: recovery)
        }
        if contacts.count > 1 {
            throw ToolFailureError("More than one agent contact matches \(text). Choose its exact address from agent.contacts. Nothing ran.",
                argumentPath: "$.id", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]), recovery: .inspect)
        }
    }
    throw botArgumentError(matches.isEmpty ? "No helper matches \(text). Use an id from bot.list."
        : "More than one helper has that name; use its UUID from bot.list.",
        field: "id", accepted: "A helper UUID or exact name from bot.list.")
}

/// The Bots editor's "On an event", checked the way the editor checks it.
private func botEventTrigger(_ trigger: BotEventFields) throws -> BotEventTrigger {
    let raw = try botString(trigger.source, field: "event_trigger.source")
    guard let source = BotEventSource(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
        throw botArgumentError("event_trigger.source must be slack", field: "event_trigger.source", accepted: "slack.")
    }
    let filter = try botString(trigger.filter, field: "event_trigger.filter").trimmingCharacters(in: .whitespacesAndNewlines)
    // Slack delivers a channel ID, never a name, so a name would never match.
    if !BotEventTrigger.isChannelID(filter) {
        throw botArgumentError("""
            A Slack trigger needs the channel ID, such as C0123ABCD, not its name. In Slack, open the channel, choose View channel details, and \
            copy the ID at the bottom.
            """, field: "event_trigger.filter", accepted: "A Slack channel ID such as C0123ABCD.")
    }
    let keyword = trigger.keyword
    return BotEventTrigger(source: source, filter: filter.uppercased(), keyword: keyword)
}

private var botTriggerTimingError: ToolFailureError { botArgumentError(
    "An event-woken helper keeps no schedule: the event is what runs it. Drop schedule and cadence, or use schedule manual.",
    field: "event_trigger", accepted: "event_trigger with no schedule, or with schedule manual.") }

/// Both pre-approval and persistence call this adapter; cadence validity and the operator's minimum interval still belong to BotDefinitionStore.
private func botRequestedCadence(_ args: BotSettingsFields) throws -> BotCadence? {
    guard args.schedule != nil else {
        return args.cadence?.value
    }
    guard args.cadence == nil else {
        throw botArgumentError("Use schedule or cadence, not both", field: "schedule", accepted: "Supply schedule or cadence, not both.")
    }
    do {
        return try StandingBotSchedule.parse(botString(args.schedule, field: "schedule"))
    } catch StandingBotsError.invalidValue(let message) {
        throw ToolFailureError(message, argumentPath: "$", accepted: """
            schedule: manual; every N minutes or hours; daily at HH:mm; weekdays at HH:mm; weekly on DAY at HH:mm. Clock: 00:00-23:59 on this \
            Mac's local clock.
            """, effects: .none)
    }
}

private func botJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
}

private func botDefinitionJSON(_ bot: BotDefinition, details: Bool = false, operation: String? = nil, currentModel: String? = nil,
    notes: [String] = []) throws -> JSONValue {
    guard case .object(var fields) = try botJSON(bot) else { throw StandingBotsError.invalidValue("bot") }
    if !details {
        let visible: Set<String> = ["id", "name", "personality", "brief", "provider", "model", "modelPinned", "reasoningEffort", "fast",
                                   "cadence", "paused", "budget", "eventTrigger", "notificationCondition"]
        fields = fields.filter { visible.contains($0.key) }
    }
    fields["status"] = .string("ok")
    if !notes.isEmpty { fields["notes"] = .array(notes.map(JSONValue.string)) }
    fields["model_selection"] = .string(bot.modelSelection(currentModel: currentModel))
    fields["session_id"] = .string(bot.sessionID)
    fields["daily_token_ceiling"] = bot.dailyTokenCeiling.map { .int(Int64($0)) } ?? .string("none")
    fields["schedule"] = .string(StandingBotSchedule.describe(bot.cadence))
    if case .cron = bot.cadence {
        fields["mac_timezone"] = .string(TimeZone.current.identifier)
        fields["timezone_detail"] = .string("Follows the Mac: \(TimeZone.current.identifier).")
    }
    fields["scheduler_status"] = .string(bot.paused ? "paused" : bot.eventTrigger != nil ? "on_event" : bot.cadence == .manual ? "manual" : "scheduled")
    let reference = JSONValue.string(bot.name)
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
            fields["detail"] = .string("""
                Saved paused as manual; this call did not run the helper. No timing was given: ask the person when it should run, such as daily \
                at 09:00, weekdays at 08:30 or weekly on monday at 09:00, then set it with bot_update schedule. Manual messages and run once \
                remain available.
                """)
        case "created" where bot.paused:
            fields["operation"] = .string("created")
            fields["detail"] = .string("""
                Saved paused; this call did not run the helper. Scheduled turns stay paused until resumed with bot_pause paused false. Manual \
                messages and run once remain available.
                """)
        case "created":
            fields["detail"] = .string(
                "Saved; this call did not run the helper. Send a message or run once when ready. Scheduled turns follow the saved timing.")
        case "created without timing":
            fields["operation"] = .string("created")
            fields["detail"] = .string("""
                Saved as manual; this call did not run the helper. No timing was given: ask the person when it should run, such as daily at \
                09:00, weekdays at 08:30 or weekly on monday at 09:00, then set it with bot_update schedule.
                """)
        case "paused":
            fields["detail"] = .string("""
                Scheduled turns are paused. Any in-flight run is not cancelled. Manual messages and run once remain available; context and saved \
                replies are preserved.
                """)
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

/// Whether a bots call has begun a write, so a failure reports unknown effects rather than none.
private final class BotCallProgress {
    var writeStarted = false
}
