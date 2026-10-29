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
// Blueprint: | `AgentContactTaskCallbacks.swift` | Persisted callback delivery and recovery |
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
            if let config = pushConfigs[taskID]?.removeValue(forKey: id) { try? AgentPeerCredentials.deleteSecret(account: config.account) }
            let key = taskID + ":" + id
            if let delivery = pushDeliveries.removeValue(forKey: key) {
                delivery.worker.cancel()
                // Join an already-started bounded POST before acknowledging deletion.
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
        guard bridgeIsActive, (try? DataRootLife.isCurrent(task.lifeID, in: dataRoot)) == true else { return }
        guard let configs = pushConfigs[task.id]?.filter({ owed?.contains($0.key) ?? true }), !configs.isEmpty else { return }
        // A status event contains only the protocol locator and state. Peers fetch
        // artifacts through their authenticated task API instead of webhook copies.
        let event: [String: Any] = ["taskId": task.id, "contextId": task.context,
                                   "status": ["state": task.state.rawValue]]
        guard let canonical = try? NativeAgentA2AWire.project(event, version: "1.0"),
              let payload = try? JSONSerialization.data(withJSONObject: ["statusUpdate": canonical]) else { return }
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
                let accepted = await config.deliver(payload)
                // Deletion or replacement while the POST was pending owns the outcome now.
                guard self.bridgeIsActive, !Task.isCancelled, self.pushConfigs[task.id]?[config.id]?.generation == config.generation else { return }
                self.recordCallback(task, config: config, accepted: accepted)
            })
        }
    }
    /// The callback's outcome is part of the durable task: accepted, or an
    /// owed failure with its cause that a relaunch delivers again. Once a
    /// terminal update is accepted the callback's secret is no longer needed.
    private func recordCallback(_ sent: AgentContactTask, config: AgentContactPushConfig, accepted: Bool) {
        do {
            // Eviction does not make the sent snapshot current again. Patch the
            // retained task under this actor, preserving its reply and outcome.
            // The live record first; a reread (which can recover and push again) only once evicted.
            var task = try records[sent.id]?.task ?? get(sent.id, owner: sent.owner)
            guard var callback = task.callbacks?[config.id], callback.account == config.account else { return }
            if accepted { callback.delivered = sent.state.rawValue }
            callback.failure = accepted ? nil : "The callback did not accept the \(sent.state.rawValue) update after three attempts."
            task.callbacks?[config.id] = callback
            try retain(task)
            records[sent.id]?.task = task
            if accepted, sent.state.terminal { try? AgentPeerCredentials.deleteSecret(account: config.account) }
        }
        catch { nativeLog("[a2a] callback outcome could not be saved for %@: %@", sent.id, error.localizedDescription) }
    }
    private func updateCallbacks(_ taskID: String, owner: String, _ change: (inout [String: AgentContactCallback]) -> Void) throws {
        var task = try get(taskID, owner: owner)
        var callbacks = task.callbacks ?? [:]
        change(&callbacks)
        task.callbacks = callbacks
        try retain(task)
        records[taskID]?.task = task
    }
    /// A task read back from disk resumes its callbacks, and any whose last
    /// accepted update is not the task's state is owed it again.
    func restoreCallbacks(_ task: AgentContactTask) {
        var owed: Set<String> = []
        guard bridgeIsActive, (try? DataRootLife.isCurrent(task.lifeID, in: dataRoot)) == true else { return }
        for (id, callback) in task.callbacks ?? [:] where pushConfigs[task.id]?[id] == nil {
            guard let config = try? AgentContactPushConfig.restored(callback, id: id, taskId: task.id) else { continue }
            pushConfigs[task.id, default: [:]][id] = config
            if callback.delivered != task.state.rawValue { owed.insert(id) }
        }
        if !owed.isEmpty { notifyPush(task, only: owed) }
    }
    /// Owed terminal callbacks remain here even when no live record holds them.
    /// Activation and launch recovery read the same persisted task set.
    func retainedTasksAwaitingRecovery() throws -> [AgentContactTask] {
        let tasks = try retainedTasks()
        guard let life = tasks.isEmpty ? nil : try DataRootLife.current(in: dataRoot) else { return [] }
        return tasks.filter { DataRootLife.life(of: $0.lifeID) == life && (!$0.state.terminal || $0.owesCallbacks) }
    }
    /// At launch: every retained task whose callback is still owed an update
    /// gets it, and every one still open recovers without waiting for its peer.
    /// The turns a restart left in each conversation (queued, or interrupted
    /// with a checkpoint) go back into its admission in the order they were
    /// said there, before anything new is admitted; a queued one runs from its
    /// saved input. One strict read of each conversation supplies both.
    public func redeliverOwedCallbacks() async {
        guard let open = try? retainedTasksAwaitingRecovery() else {
            launchRecovered = true
            await TurnAdmission.shared.restorationComplete()
            return
        }
        var backlog: [AgentContactTask] = []
        for (session, tasks) in Dictionary(grouping: open.filter { !$0.state.terminal && $0.canonicalRunID != nil }, by: { $0.canonicalSession ?? "" })
            where !session.isEmpty {
            let inputs: [CodexCompletionTranscriptEvidence.SavedTurnInput]
            do { inputs = try await CodexCompletionTranscriptEvidence.savedTurnInputs(dataRoot: dataRoot, sessionId: session) }
            catch {
                nativeLog("AgentContactTasks: %@'s saved turns cannot be read, so they do not resume: %@", session, error.localizedDescription)
                continue
            }
            let place = Dictionary(inputs.enumerated().map { ($1.runId, $0) }, uniquingKeysWith: { first, _ in first })
            let said = tasks.filter { place[$0.canonicalRunID ?? ""] != nil }.sorted { place[$0.canonicalRunID!]! < place[$1.canonicalRunID!]! }
            await TurnAdmission.shared.restore(sessionID: session, runs: said.compactMap(\.canonicalRunID))
            for task in said {
                let input = inputs[place[task.canonicalRunID!]!]
                if input.awaitingConsumption, let turn = queuedTurn(task, input: input) { restoredInput[task.id] = turn }
            }
            backlog += said
        }
        launchRecovered = true
        // Every backlog is back: contact conversations admit new turns behind it.
        await TurnAdmission.shared.restorationComplete()
        // A task read before this point holds a placeholder: read it again now.
        for (id, record) in records where record.worker == nil && record.task.detail == Self.recovering {
            records.removeValue(forKey: id); order.removeAll { $0 == id }
        }
        for task in open { _ = try? get(task.id, owner: task.owner) }
        // A restored run nothing resumes gives up its place.
        for task in backlog where !resuming.contains(task.id) {
            await TurnAdmission.shared.withdraw(sessionID: task.canonicalSession!, runID: task.canonicalRunID!)
        }
        restoredInput.removeAll()
    }
}
