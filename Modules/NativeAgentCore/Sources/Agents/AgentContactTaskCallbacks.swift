import Foundation
import NativeAgentShared
import ChatTurnRuntime
import AgentWorkspace
import ChatToolParsing
import AgentLinkTransport
import NativeAgentCore
import PersistenceCore
import AgentConversations
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting
import CryptoKit
import SQLite3
import Experiences
// Blueprint: | `AgentContactTaskCallbacks.swift` | Durable callbacks retain per-task recovery debt. |
extension AgentContactTasks {
    func push(operation: String, owner: String, parameters: JSONValue) async throws -> JSONValue {
        guard let params = parameters.foundationObject as? [String: Any],
              let taskID = params["taskId"] as? String else { throw AgentContactPushConfig.invalid }
        _ = try get(taskID, owner: owner)
        switch operation {
        case "CreateTaskPushNotificationConfig":
            let config = try await AgentContactPushConfig.parse(parameters, taskID: taskID)
            _ = try get(taskID, owner: owner)
            guard pushConfigs[taskID]?[config.id] == nil else {
                throw AgentContactFailure(code: -32602, message: "That push configuration already exists")
            }
            guard (pushConfigs[taskID]?.count ?? 0) < 8 else {
                throw AgentContactFailure(code: -32004, message: "Too many push notification configurations")
            }
            try config.keep()
            try updateCallbacks(taskID, owner: owner) { $0[config.id] = config.callback }
            pushConfigs[taskID, default: [:]][config.id] = config
            return try config.value
        case "GetTaskPushNotificationConfig":
            guard let id = params["id"] as? String, let config = pushConfigs[taskID]?[id] else { throw AgentContactFailure.missing }
            return try config.value
        case "DeleteTaskPushNotificationConfig":
            guard let id = params["id"] as? String, !id.isEmpty else { throw AgentContactPushConfig.invalid }
            // Keep the live config through the retained read so it cannot be restored by deletion.
            try updateCallbacks(taskID, owner: owner) { $0[id] = nil }
            if let config = pushConfigs[taskID]?.removeValue(forKey: id) { try AgentPeerCredentials.deleteSecret(account: config.account) }
            let key = taskID + ":" + id
            if let delivery = pushDeliveries.removeValue(forKey: key) {
                delivery.worker.cancel()
                // Join the actual POST before acknowledging deletion.
                await delivery.worker.value
            }
            return .object([:])
        case "ListTaskPushNotificationConfigs":
            let size: Int
            if let raw = params["pageSize"] {
                guard NativeAgentA2AWire.validHistoryLength(raw), let n = raw as? NSNumber,
                      (1...100).contains(n.intValue) else { throw AgentContactPushConfig.invalid }
                size = n.intValue
            } else { size = 50 }
            let cursor: String
            if let token = params["pageToken"] {
                guard let text = token as? String else { throw AgentContactPushConfig.invalid }
                cursor = text
            } else { cursor = "" }
            let configs = (pushConfigs[taskID]?.values.map { $0 } ?? []).sorted { $0.id < $1.id }
            guard cursor.isEmpty || configs.contains(where: { $0.id == cursor }) else { throw AgentContactPushConfig.invalid }
            let remaining = configs.filter { cursor.isEmpty || $0.id > cursor }
            let page = Array(remaining.prefix(size))
            return .object(["configs": .array(try page.map { try $0.value }),
                            "nextPageToken": .string(remaining.count > page.count ? (page.last?.id ?? "") : "")])
        default: throw AgentContactFailure(code: -32601, message: "Unknown push notification operation")
        }
    }
    func notifyPush(_ task: AgentContactTask, only owed: Set<String>? = nil) {
        guard bridgeIsActive else { return }
        do { guard try DataRootLife.isCurrent(task.lifeID, in: dataRoot) else { return } }
        catch { callbackRepair(task.id, operation: "life", error: error); return }
        guard let configs = pushConfigs[task.id]?.filter({ owed?.contains($0.key) ?? true }), !configs.isEmpty else { return }
        // Callbacks carry locators and state only; artifacts require the peer’s authenticated task API.
        let event: [String: Any] = ["taskId": task.id, "contextId": task.context,
                                   "status": ["state": task.state.rawValue]]
        let payload: Data
        do {
            let canonical = try NativeAgentA2AWire.project(event, version: "1.0")
            payload = try JSONSerialization.data(withJSONObject: ["statusUpdate": canonical])
        } catch { callbackRepair(task.id, operation: "encode", error: error); return }
        for config in configs.values {
            let key = task.id + ":" + config.id
            let previous = pushDeliveries[key]
            let generation = UUID()
            pushDeliveries[key] = (generation, Task {
                defer {
                    if self.pushDeliveries[key]?.generation == generation {
                        self.pushDeliveries.removeValue(forKey: key)
                    }
                }
                await withTaskCancellationHandler {
                    await previous?.worker.value
                } onCancel: { previous?.worker.cancel() }
                guard self.bridgeIsActive, !Task.isCancelled, self.pushConfigs[task.id]?[config.id]?.generation == config.generation else { return }
                let failure: String?
                do { try await config.deliver(payload); failure = nil }
                catch { failure = (error as? AgentContactFailure)?.message ?? error.localizedDescription }
                // Deletion or replacement while the POST was pending owns the outcome now.
                guard self.bridgeIsActive, !Task.isCancelled, self.pushConfigs[task.id]?[config.id]?.generation == config.generation else { return }
                self.recordCallback(task, config: config, failure: failure)
            })
        }
    }
    /// Persist callback outcomes so owed failures survive relaunch; retire secrets only after accepted terminal updates.
    private func recordCallback(_ sent: AgentContactTask, config: AgentContactPushConfig, failure: String?) {
        do {
            // Eviction cannot make a sent snapshot current; patch the live record before any reread that could restore callbacks.
            var task = try records[sent.id]?.task ?? get(sent.id, owner: sent.owner)
            guard var callback = task.callbacks?[config.id], callback.account == config.account else { return }
            if failure == nil { callback.delivered = sent.state.rawValue }
            callback.failure = failure
            guard task.callbacks?[config.id] != callback else { return }
            task.callbacks?[config.id] = callback
            try retain(task)
            records[sent.id]?.task = task
            if failure == nil, sent.state.terminal { try AgentPeerCredentials.deleteSecret(account: config.account) }
        }
        catch { callbackRepair(sent.id, operation: "outcome", error: error) }
    }
    private func updateCallbacks(_ taskID: String, owner: String, _ change: (inout [String: AgentContactCallback]) -> Void) throws {
        var task = try get(taskID, owner: owner)
        var callbacks = task.callbacks ?? [:]
        change(&callbacks)
        task.callbacks = callbacks
        try retain(task)
        records[taskID]?.task = task
    }
    /// Resume callbacks only when the task’s durable state is newer than its accepted update.
    func restoreCallbacks(_ task: AgentContactTask) {
        var owed: Set<String> = []
        guard bridgeIsActive else { return }
        do { guard try DataRootLife.isCurrent(task.lifeID, in: dataRoot) else { return } }
        catch { callbackRepair(task.id, operation: "life", error: error); return }
        for (id, callback) in task.callbacks ?? [:] where pushConfigs[task.id]?[id] == nil {
            // Accepted terminal callbacks have deliberately retired their secret.
            if task.state.terminal, callback.delivered == task.state.rawValue { continue }
            do {
                let config = try AgentContactPushConfig.restored(callback, id: id, taskId: task.id)
                pushConfigs[task.id, default: [:]][id] = config
                if callback.delivered != task.state.rawValue { owed.insert(id) }
            } catch {
                recordRestorationFailure(task, id: id, account: callback.account, error: error)
            }
        }
        if !owed.isEmpty { notifyPush(task, only: owed) }
    }

    private func recordRestorationFailure(_ sent: AgentContactTask, id: String, account: String, error: Error) {
        do {
            // Read the durable owner without get(), which itself restores callbacks.
            guard var task = try records[sent.id]?.task ?? retainedTasks(id: sent.id, owner: sent.owner).first,
                  var callback = task.callbacks?[id], callback.account == account else { return }
            let cause = (error as? AgentContactFailure)?.message ?? error.localizedDescription
            let failure = "Callback restoration failed: \(cause). Repair its Keychain entry, then read the task or activate the bridge to restore it."
            guard callback.failure != failure else { return }
            callback.failure = failure
            task.callbacks?[id] = callback
            try retain(task)
            records[task.id]?.task = task
        } catch {
            callbackRepair(sent.id, operation: "restore", error: error)
        }
    }

    private func callbackRepair(_ taskID: String, operation: String, error: Error) {
        RepairOwed.owe(dataRoot, id: "callback:" + taskID, kind: .message,
            operation: "contact.callback." + operation + ":" + taskID, owner: taskID,
            words: "The retained callback's \(operation) failed: " + error.localizedDescription + ". Its update remains owed.",
            lever: "Repair the named callback or retained task, then read this task to resume its owed update.")
    }

    /// Owed terminal callbacks survive eviction and share the same persisted recovery set.
    func retainedTasksAwaitingRecovery() throws -> [AgentContactTask] {
        let tasks = try retainedTasks(requireComplete: true)
        guard let life = tasks.isEmpty ? nil : try DataRootLife.current(in: dataRoot) else { return [] }
        return tasks.filter { DataRootLife.life(of: $0.lifeID) == life && (!$0.state.terminal || $0.owesCallbacks) }
    }
    /// Restore each conversation’s queued or checkpointed turns in order before admitting new input. One strict conversation read supplies both task recovery
    /// and backlog admission.
    public func redeliverOwedCallbacks() async {
        let open: [AgentContactTask]
        let source = dataRoot.appendingPathComponent("agents/a2a-receipts/outcomes.sqlite").path
        do { open = try retainedTasksAwaitingRecovery() }
        catch {
            let detail = """
                Contact backlog restoration could not read \(source): \(error.localizedDescription). Repair this retained task store, then restart \
                recovery; do not resend accepted messages.
                """
            RepairOwed.owe(dataRoot, id: "contact-backlog", kind: .message, operation: "contact.backlog.restore",
                owner: source, words: detail, lever: "Repair the named retained task store and restart NativeAgent to resume recovery.")
            await TurnAdmission.shared.restorationFailed(detail)
            return
        }
        RepairOwed.settle(dataRoot, operation: "contact.backlog.restore", evidence: .init(source: source, id: "contact-backlog"))
        var backlog: [AgentContactTask] = []
        var unavailableSessions: Set<String> = []
        for (session, tasks) in Dictionary(grouping: open.filter { !$0.state.terminal && $0.canonicalRunID != nil }, by: { $0.canonicalSession ?? "" })
            where !session.isEmpty {
            let inputs: [CodexCompletionTranscriptEvidence.SavedTurnInput]
            do { inputs = try await CodexCompletionTranscriptEvidence.savedTurnInputs(dataRoot: dataRoot, sessionId: session) }
            catch {
                let transcript = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl").path
                let detail = """
                    Contact backlog restoration could not read \(transcript): \(error.localizedDescription). Repair this conversation and restart \
                    recovery; do not resend its messages.
                    """
                RepairOwed.owe(dataRoot, id: session, kind: .message, operation: "contact.backlog.restore:" + session,
                    owner: transcript, words: detail, lever: "Repair the named conversation transcript and restart NativeAgent.")
                await TurnAdmission.shared.restorationFailed(detail, sessionID: session)
                unavailableSessions.insert(session)
                continue
            }
            let place = Dictionary(inputs.enumerated().map { ($1.runId, $0) }, uniquingKeysWith: { first, _ in first })
            let said = tasks.filter { place[$0.canonicalRunID ?? ""] != nil }.sorted { place[$0.canonicalRunID!]! < place[$1.canonicalRunID!]! }
            var queued: [String: AgentContactTurn] = [:]
            do {
                for task in said {
                    let input = inputs[place[task.canonicalRunID!]!]
                    guard input.awaitingConsumption else { continue }
                    _ = try input.attachments.get()
                    guard let turn = queuedTurn(task, input: input) else {
                        throw AgentContactFailure(code: -32603, message: "Queued task \(task.id) could not recover its exact sender, words or files.")
                    }
                    queued[task.id] = turn
                }
            } catch {
                let transcript = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl").path
                let detail = """
                    Contact backlog restoration could not recover \(transcript): \(error.localizedDescription). Repair the exact queued input, then \
                    restart recovery; nothing was resent.
                    """
                RepairOwed.owe(dataRoot, id: session, kind: .message, operation: "contact.backlog.restore:" + session,
                    owner: transcript, words: detail,
                        lever: "Repair the queued sender, transcript or attachment named by this failure, then restart NativeAgent.")
                await TurnAdmission.shared.restorationFailed(detail, sessionID: session)
                unavailableSessions.insert(session)
                continue
            }
            RepairOwed.settle(dataRoot, operation: "contact.backlog.restore:" + session,
                evidence: .init(source: "chat/messages/\(session).jsonl", id: session))
            await TurnAdmission.shared.restore(sessionID: session, runs: said.compactMap(\.canonicalRunID))
            restoredInput.merge(queued) { _, current in current }
            backlog += said
        }
        launchRecovered = true
        // Admit new contact turns only after every backlog is restored.
        await TurnAdmission.shared.restorationComplete()
        // Reread placeholders after backlog admission opens.
        for (id, record) in records where record.worker == nil && record.task.detail == Self.recovering {
            records.removeValue(forKey: id); order.removeAll { $0 == id }
        }
        for task in open where !unavailableSessions.contains(task.canonicalSession ?? "") {
            do { _ = try get(task.id, owner: task.owner) }
            catch {
                RepairOwed.owe(dataRoot, id: task.id, kind: .message, operation: "contact.task.restore:" + task.id,
                    owner: source, words: "Task \(task.id) could not be restored: \(error.localizedDescription). Its saved evidence was preserved.",
                    lever: "Repair this task's exact retained receipt or transcript and read it again; do not resend the work.")
            }
        }
        // A restored run that cannot resume must release its admission place.
        for task in backlog where !resuming.contains(task.id) {
            await TurnAdmission.shared.withdraw(sessionID: task.canonicalSession!, runID: task.canonicalRunID!)
        }
        restoredInput.removeAll()
    }
}
