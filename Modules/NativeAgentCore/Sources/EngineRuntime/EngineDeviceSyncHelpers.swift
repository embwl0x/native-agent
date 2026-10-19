import Foundation
import BackgroundWork
import DeviceSync
import NativeAgentShared
import PersistenceCore
import StandingBots
import ProviderRouting
import ChatOrchestration
import Experiences

extension NativeAgentEngine {
    public func deviceHelpersSnapshot() async throws -> MobileHelpersSnapshot {
        let root = dataRoot
        return try await Task.detached(priority: .utility) {
            let records = try BotsShelfRecord.read(root: root)
            let running = try BotRunQueue(dataRoot: root).activeOrQueuedIDs()
            let threads = try await AgentContactThreads.mobileThreads(root: root)
            let store = ExperienceStore.at(root)
            var snapshot = MobileHelpersSnapshot()
            for record in records.prefix(100) {
                var row = MobileHelperRow(id: record.id, name: record.definition.name,
                    status: running.contains(record.id) ? "Running or queued" : record.state,
                    paused: record.definition.paused,
                    canPause: record.definition.cadence != .manual || record.definition.eventTrigger != nil || record.definition.paused)
                if let latest = record.entries.filter({ $0.runtimeStatus == .completed }).max(by: { $0.runAt < $1.runAt }) {
                    row.resultID = latest.id.uuidString
                    row.resultPreview = try await store.experience(latest.id.uuidString)?.face.map {
                        MobileDeskProjectionBounds.clipped($0.words, to: 160)
                    }
                }
                snapshot.helpers.append(row)
            }
            snapshot.agents = threads.prefix(100).map {
                var row = $0.agent
                row.experienceIDs = row.experiences?.map(\.id)
                row.experiences = nil
                return row
            }
            snapshot.truncated = records.count > 100 || threads.count > 100
            return snapshot
        }.value
    }

    public func deviceHelperAction(action: String, payload: [String: String]) async throws -> [String: String] {
        let root = dataRoot
        let store = BotDefinitionStore(dataRoot: root)
        let id = payload["id"].flatMap(UUID.init(uuidString:))
        switch action {
        case "save_helper":
            guard let text = payload["edit"], text.utf8.count <= 64 * 1024 else { throw HelperRemoteError.invalid }
            let edit = try JSONDecoder().decode(MobileHelperEdit.self, from: Data(text.utf8))
            var bot: BotDefinition
            if let id = edit.id {
                bot = try store.get(id)
                guard bot.deleted != true, edit.revision == bot.updatedAt.timeIntervalSinceReferenceDate else {
                    throw HelperRemoteError.stale
                }
            } else {
                bot = BotDefinition(name: edit.name, brief: edit.brief, cadence: .manual,
                                    budget: BotBudget(tokens: BotRunLimits.maximumTokens, seconds: BotRunLimits.maximumSeconds))
            }
            let modelPinned = edit.modelPinned ?? ((!edit.provider.isEmpty && !edit.model.isEmpty) || bot.modelPinned == true)
            if modelPinned {
                let providers = try await self.providers.list()
                guard let provider = providers.first(where: { $0.provider_id == edit.provider && $0.auth_status.eligible }),
                      let model = provider.models.first(where: { $0.id == edit.model }),
                      (model.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"]).contains(edit.think),
                      !edit.fast || model.supports_fast == true else { throw HelperRemoteError.model }
            }
            let tokens = edit.tokens.isEmpty ? BotRunLimits.maximumTokens : Int(edit.tokens) ?? 0
            let seconds = edit.seconds.isEmpty ? BotRunLimits.maximumSeconds : Double(edit.seconds) ?? 0
            let daily = edit.daily.isEmpty ? BotRunLimits.dailyTokens : Int(edit.daily) ?? 0
            guard tokens > 0, seconds.isFinite, seconds > 0, daily > 0,
                  !edit.tell || !edit.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HelperRemoteError.invalid
            }
            bot.name = edit.name; bot.brief = edit.brief; bot.outputFormat = nil
            bot.provider = edit.provider; bot.model = edit.model; bot.reasoningEffort = edit.think; bot.fast = edit.fast
            bot.modelPinned = modelPinned
            if !modelPinned { bot.followProviders() }
            bot.budget = BotBudget(tokens: tokens, seconds: seconds); bot.dailyTokenCeiling = daily
            bot.notificationCondition = edit.tell ? edit.condition : nil
            bot.eventTrigger = nil
            switch edit.timing {
            case "manual": bot.cadence = .manual
            case "interval":
                guard let hours = Double(edit.hours), hours.isFinite, hours > 0 else { throw HelperRemoteError.invalid }
                bot.cadence = .interval(seconds: hours * 3600)
            case "cron": bot.cadence = .cron(expression: edit.cron, timeZone: BotCadence.setZone(edit.timeZone))
            case "event":
                guard let source = BotEventSource(rawValue: edit.eventSource),
                      !edit.eventFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HelperRemoteError.invalid }
                bot.cadence = .manual
                bot.eventTrigger = BotEventTrigger(source: source, filter: edit.eventFilter, keyword: edit.eventKeyword)
            default: throw HelperRemoteError.invalid
            }
            let recovered = try edit.id == nil ? store.create(bot) : store.update(bot)
            return try helperReceipt(store.get(recovered.id))
        case "get_helper", "pause_helper", "run_helper":
            guard let id else { throw HelperRemoteError.invalid }
            guard try store.get(id).deleted != true else { throw HelperRemoteError.stale }
            var runID: UUID?
            if action == "pause_helper" {
                guard let paused = payload["paused"], ["true", "false"].contains(paused) else { throw HelperRemoteError.invalid }
                _ = try store.pause(id, paused: paused == "true")
            } else if action == "run_helper" {
                runID = try await BotRunConversation.enqueueRequestedCheck(botID: id, dataRoot: root)
            }
            var result = try helperReceipt(store.get(id))
            if let resultID = payload["result_id"] {
                guard let resultID = UUID(uuidString: resultID) else { throw HelperRemoteError.invalid }
                let entry = try ShelfStore(dataRoot: root).entry(resultID)
                guard entry.botId == id else { throw HelperRemoteError.invalid }
                let experiences = ExperienceStore.at(root)
                _ = try await experiences.projection()
                guard let experience = try await experiences.experience(resultID.uuidString) else { throw HelperRemoteError.stale }
                result["result"] = String(decoding: try JSONEncoder().encode(experience.mobile), as: UTF8.self)
            }
            if let runID { result["run_id"] = runID.uuidString; result["message"] = "Run queued." }
            return result
        default: throw HelperRemoteError.invalid
        }
    }

    public func deviceAgentThreadAction(action: String, payload: [String: String]) async throws -> [String: String] {
        let root = dataRoot
        guard let id = payload["id"] else { throw HelperRemoteError.invalid }
        let threads = try await Task.detached(priority: .utility) { try await AgentContactThreads.mobileThreads(root: root) }.value
        guard threads.contains(where: { $0.agent.id == id }) else { throw HelperRemoteError.contact }
        var refreshed = threads
        if action == "send_agent_message" {
            guard let text = payload["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 16_000, let session = payload["session_id"],
                  try await transcripts.list().contains(where: { $0.id == session }) else { throw HelperRemoteError.session }
            if let failure = await sendContactMessage(agent: id, text: text, session: session, root: root) {
                return ["status": "error", "message": failure]
            }
            refreshed = try await Task.detached(priority: .utility) { try await AgentContactThreads.mobileThreads(root: root) }.value
        }
        guard let thread = refreshed.first(where: { $0.agent.id == id }) else { throw HelperRemoteError.contact }
        return ["status": "ok", "thread": String(decoding: try JSONEncoder().encode(thread), as: UTF8.self)]
    }

    private func helperReceipt(_ bot: BotDefinition) throws -> [String: String] {
        var edit = MobileHelperEdit()
        edit.id = bot.id; edit.revision = bot.updatedAt.timeIntervalSinceReferenceDate
        edit.name = bot.name; edit.brief = [bot.brief, bot.outputFormat ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        edit.provider = bot.provider ?? ""; edit.model = bot.model ?? ""; edit.think = bot.reasoningEffort ?? ""; edit.fast = bot.fast ?? false
        edit.modelPinned = bot.modelPinned ?? false
        edit.tokens = String(bot.budget.tokens); edit.seconds = String(bot.budget.seconds)
        edit.daily = bot.dailyTokenCeiling.map(String.init) ?? ""
        edit.tell = bot.notificationCondition != nil; edit.condition = bot.notificationCondition ?? ""
        switch bot.cadence {
        case .manual: edit.timing = "manual"
        case .interval(let seconds): edit.timing = "interval"; edit.hours = String(seconds / 3600)
        case .cron(let expression, let zone): edit.timing = "cron"; edit.cron = expression; edit.timeZone = zone ?? ""
        }
        if let trigger = bot.eventTrigger {
            edit.timing = "event"; edit.eventSource = trigger.source.rawValue
            edit.eventFilter = trigger.filter; edit.eventKeyword = trigger.keyword ?? ""
        }
        let running = try BotRunQueue(dataRoot: dataRoot).activeOrQueuedIDs().contains(bot.id)
        let row = MobileHelperRow(id: bot.id, name: bot.name,
            status: running ? "Running or queued" : bot.paused ? "Paused" : bot.needsModelChoice ? "Choose a model" : "Ready",
            paused: bot.paused, canPause: bot.cadence != .manual || bot.eventTrigger != nil || bot.paused)
        return ["status": "ok", "helper": String(decoding: try JSONEncoder().encode(edit), as: UTF8.self),
                "helper_row": String(decoding: try JSONEncoder().encode(row), as: UTF8.self), "paused": String(bot.paused)]
    }
}

private enum HelperRemoteError: LocalizedError {
    case invalid, stale, model, contact, session
    var errorDescription: String? {
        switch self {
        case .invalid: "Check the helper fields, timing, and positive execution limits."
        case .stale: "This helper changed on the Mac. Reopen it before saving."
        case .model: "Choose Follow Providers or pin a connected account, model and supported Think level."
        case .contact: "This agent is no longer reachable. Refresh the Agents page."
        case .session: "Open a chat before sending to an agent. Messages must be between 1 and 16,000 characters."
        }
    }
}

extension NativeAgentEngine {
    public func botsShelfRead(unattendedChanged: @MainActor (Bool) -> Void) async throws -> (records: [BotsShelfRecord], runs: (active: Set<UUID>, queued: Set<UUID>)) {
        let root = dataRoot
        let allowed = await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: root)
        await unattendedChanged(allowed)
        let followingModel = try? await SwiftNativeProviderRouting(dataRoot: root).modelForSurface("chat").model
        return try await Task.detached(priority: .userInitiated) {
            (records: try BotsShelfRecord.read(root: root, unattended: allowed, followingModel: followingModel),
             runs: try BotRunQueue(dataRoot: root).activeAndQueuedIDs())
        }.value
    }
}
