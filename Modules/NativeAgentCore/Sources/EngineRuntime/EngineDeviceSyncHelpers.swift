import Foundation
import BackgroundWork
import DeviceSync
import NativeAgentShared
import PersistenceCore
import StandingBots
import ProviderRouting
import ChatToolRuntime
import Experiences
// Blueprint: | `EngineDeviceSyncHelpers.swift` | Phone helper edit validation, revisions, provider pin/follow semantics and contact commands; `editBotDefinition` fresh merge/timing; `botsShelfRead` supplies one helper status projection to Mac and DeviceSync; action receipts use the committed definition independently of snapshot refresh, whose `helpers_snapshot_error` marks the phone's shared helpers snapshot stale without failing the committed action; successful refresh replaces it without status overrides |

extension NativeAgentEngine {
    public func deviceHelpersSnapshot() async throws -> MobileHelpersSnapshot {
        let root = dataRoot
        let records = try await botsShelfRead()
        return try await Task.detached(priority: .utility) {
            let threads = try await AgentContactThreads.mobileThreads(root: root, contacts: self.contacts)
            var snapshot = MobileHelpersSnapshot()
            for record in records.prefix(100) {
                var row = MobileHelperRow(id: record.id, name: record.definition.name,
                    status: record.statusWord,
                    paused: record.definition.paused,
                    canPause: record.definition.cadence != .manual || record.definition.eventTrigger != nil || record.definition.paused)
                row.revision = record.definition.updatedAt.timeIntervalSinceReferenceDate
                if let latest = try await AgentContactThreads.helperResults(record, root: root, historyLimit: 0).latestCompleted {
                    row.resultID = latest.id.uuidString
                    row.resultPreview = latest.preview.map {
                        MobileDeskProjectionBounds.clipped($0, to: 160)
                    }
                }
                snapshot.helpers.append(row)
            }
            snapshot.agents = threads.prefix(100).map { $0.agent.summary }
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
            let bot: BotDefinition
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
            var selectedModel: ProviderModelInfo?
            if modelPinned {
                let providers = try await self.providers.list().providers
                guard let provider = providers.first(where: { $0.provider_id == edit.provider && $0.auth_status.eligible }),
                      let model = provider.models.first(where: { $0.id == edit.model }),
                      (model.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"]).contains(edit.think),
                      !edit.fast || model.supports_fast == true else { throw HelperRemoteError.model }
                selectedModel = model
            }
            let when: String
            switch edit.timing {
            case "manual": when = "Manual only"
            case "interval": when = "Every N hours"
            case "cron": when = "Custom"
            case "event": when = "On an event"
            default: throw HelperRemoteError.invalid
            }
            guard let source = BotEventSource(rawValue: edit.timing == "event" ? edit.eventSource : "slack") else { throw HelperRemoteError.invalid }
            var candidate: BotDefinition
            do {
                candidate = try BotDefinitionStore.editorDefinition(bot, name: edit.name, brief: edit.brief,
                    provider: edit.provider, model: edit.model, think: edit.think, modelPinned: modelPinned,
                    providerReady: selectedModel != nil, supportedEfforts: selectedModel?.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"],
                    supportsFast: selectedModel?.supports_fast == true, fast: edit.fast,
                    tokens: edit.tokens, seconds: edit.seconds, daily: edit.daily, when: when, hours: edit.hours,
                    cron: edit.cron, weekday: 0, clockText: "", timingUnchanged: false,
                    eventSource: source, eventFilter: edit.eventFilter, eventKeyword: edit.eventKeyword, tell: edit.tell, condition: edit.condition)
            } catch { throw HelperRemoteError.invalid }
            // The phone payload does not edit personality.
            candidate.personality = bot.personality
            let recovered = try edit.id == nil ? store.create(candidate) : store.update(candidate)
            return try await helperReceipt(recovered)
        case "get_helper", "pause_helper", "run_helper":
            guard let id else { throw HelperRemoteError.invalid }
            var bot = try store.get(id)
            guard bot.deleted != true else { throw HelperRemoteError.stale }
            // Read optional result detail before any effect commits.
            var resultDetail: String?
            if let resultID = payload["result_id"] {
                guard let resultID = UUID(uuidString: resultID) else { throw HelperRemoteError.invalid }
                let entry = try ShelfStore(dataRoot: root).entry(resultID)
                guard entry.botId == id else { throw HelperRemoteError.invalid }
                let experiences = ExperienceStore.at(root)
                _ = try await experiences.projection()
                guard let experience = try await experiences.experience(resultID.uuidString) else { throw HelperRemoteError.stale }
                resultDetail = String(decoding: try JSONEncoder().encode(experience.mobile), as: UTF8.self)
            }
            var runID: UUID?
            if action == "pause_helper" {
                guard let paused = payload["paused"], ["true", "false"].contains(paused) else { throw HelperRemoteError.invalid }
                bot = try store.pause(id, paused: paused == "true")
            } else if action == "run_helper" {
                runID = try await BotRunConversation.enqueueRequestedCheck(botID: id, dataRoot: root)
            }
            var result = try await helperReceipt(bot)
            result["result"] = resultDetail
            if let runID { result["run_id"] = runID.uuidString; result["message"] = "Run queued." }
            return result
        default: throw HelperRemoteError.invalid
        }
    }

    public func deviceAgentThreadAction(action: String, payload: [String: String]) async throws -> [String: String] {
        let root = dataRoot
        guard let id = payload["id"] else { throw HelperRemoteError.invalid }
        let threads = try await Task.detached(priority: .utility) { try await AgentContactThreads.mobileThreads(root: root, contacts: self.contacts) }.value
        guard threads.contains(where: { $0.agent.id == id }) else { throw HelperRemoteError.contact }
        var refreshed = threads
        if action == "send_agent_message" {
            guard let text = payload["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 16_000, let session = payload["session_id"],
                  try await transcripts.list().contains(where: { $0.id == session }) else { throw HelperRemoteError.session }
            if let failure = await sendContactMessage(agent: id, text: text, session: session, root: root) {
                return ["status": "error", "message": failure]
            }
            refreshed = try await Task.detached(priority: .utility) { try await AgentContactThreads.mobileThreads(root: root, contacts: self.contacts) }.value
        }
        guard let thread = refreshed.first(where: { $0.agent.id == id }) else { throw HelperRemoteError.contact }
        return ["status": "ok", "thread": String(decoding: try JSONEncoder().encode(thread), as: UTF8.self)]
    }

    private func helperReceipt(_ bot: BotDefinition) async throws -> [String: String] {
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
        case .cron(let expression): edit.timing = "cron"; edit.cron = expression
        }
        if let trigger = bot.eventTrigger {
            edit.timing = "event"; edit.eventSource = trigger.source.rawValue
            edit.eventFilter = trigger.filter; edit.eventKeyword = trigger.keyword ?? ""
        }
        var receipt = ["status": "ok", "helper": String(decoding: try JSONEncoder().encode(edit), as: UTF8.self),
                       "paused": String(bot.paused)]
        // The action's committed definition is its receipt. A broader read
        // failure describes snapshot freshness, never failure of that effect.
        do {
            let snapshot = try await deviceHelpersSnapshot()
            receipt["helpers_snapshot"] = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        } catch {
            receipt["helpers_snapshot_error"] = error.localizedDescription
        }
        return receipt
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
    @MainActor
    public func editBotDefinition(_ id: UUID?, edit: (BotDefinition?, Date?) throws -> BotDefinition) async throws -> BotDefinition {
        let current = try id.map { try BotDefinitionStore(dataRoot: dataRoot).get($0) }
        let timing = try await bots.effectiveSchedule()
        return try edit(current, id.flatMap { timing.dates[$0] })
    }

    public func botsShelfRead(unattendedChanged: @MainActor (Bool) -> Void = { _ in }) async throws -> [BotsShelfRecord] {
        let root = dataRoot
        let timing = try await bots.effectiveSchedule()
        await unattendedChanged(timing.unattended)
        let followingModel = try? await SwiftNativeProviderRouting(dataRoot: root).modelForSurface("chat").model
        return try await Task.detached(priority: .userInitiated) {
            try BotsShelfRecord.read(root: root, timing: timing, followingModel: followingModel)
        }.value
    }
}
