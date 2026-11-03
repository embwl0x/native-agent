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
// Blueprint: | `AgentContactTaskCallbacks.swift` | Persisted callback delivery and recovery; launch backlog failures retain named repair and unavailable admission rather than complete restoration; conversation recovery failures stay scoped; Keychain restoration faults retain their cause without accepting the update, with two bounded retries before the next read or activation retries again |
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
            if let restoration = pushRestorations.removeValue(forKey: key) {
                restoration.worker.cancel()
            }
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
            // Accepted terminal callbacks have deliberately retired their secret.
            if task.state.terminal, callback.delivered == task.state.rawValue { continue }
            let key = task.id + ":" + id
            guard pushRestorations[key] == nil else { continue }
            do {
                let config = try AgentContactPushConfig.restored(callback, id: id, taskId: task.id)
                pushConfigs[task.id, default: [:]][id] = config
                if callback.delivered != task.state.rawValue { owed.insert(id) }
            } catch {
                recordRestorationFailure(task, id: id, account: callback.account, attempt: 1, error: error)
                retryRestoration(task, id: id, account: callback.account)
            }
        }
        if !owed.isEmpty { notifyPush(task, only: owed) }
    }

    private func recordRestorationFailure(_ sent: AgentContactTask, id: String, account: String, attempt: Int, error: Error) {
        do {
            // Read the durable owner without get(), which itself restores callbacks.
            guard var task = try records[sent.id]?.task ?? retainedTasks(id: sent.id, owner: sent.owner).first,
                  var callback = task.callbacks?[id], callback.account == account else { return }
            let cause = (error as? AgentContactFailure)?.message ?? error.localizedDescription
            let next = attempt < 3 ? "Recovery will retry within this bounded pass." : "Recovery will retry on the next task read or bridge activation."
            callback.failure = "Callback restoration failed: \(cause) No update was accepted. Recovery attempt \(attempt) of 3. \(next)"
            task.callbacks?[id] = callback
            try retain(task)
            records[task.id]?.task = task
        } catch {
            nativeLog("[a2a] callback restoration failure could not be saved for %@: %@", sent.id, error.localizedDescription)
        }
    }

    private func retryRestoration(_ sent: AgentContactTask, id: String, account: String) {
        let key = sent.id + ":" + id
        let generation = UUID()
        pushRestorations[key] = (generation, Task {
            defer {
                if self.pushRestorations[key]?.generation == generation { self.pushRestorations.removeValue(forKey: key) }
            }
            for (index, delay) in [1, 2].enumerated() {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard self.bridgeIsActive, !Task.isCancelled,
                      (try? DataRootLife.isCurrent(sent.lifeID, in: self.dataRoot)) == true else { return }
                do {
                    guard let task = try self.records[sent.id]?.task ?? self.retainedTasks(id: sent.id, owner: sent.owner).first,
                          let callback = task.callbacks?[id], callback.account == account,
                          self.pushConfigs[task.id]?[id] == nil else { return }
                    if task.state.terminal, callback.delivered == task.state.rawValue { return }
                    let config = try AgentContactPushConfig.restored(callback, id: id, taskId: task.id)
                    self.pushConfigs[task.id, default: [:]][id] = config
                    if callback.delivered != task.state.rawValue { self.notifyPush(task, only: [id]) }
                    return
                } catch {
                    self.recordRestorationFailure(sent, id: id, account: account, attempt: index + 2, error: error)
                }
            }
        })
    }
    /// Owed terminal callbacks remain here even when no live record holds them.
    /// Activation and launch recovery read the same persisted task set.
    func retainedTasksAwaitingRecovery() throws -> [AgentContactTask] {
        let tasks = try retainedTasks(requireComplete: true)
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
        let open: [AgentContactTask]
        let source = dataRoot.appendingPathComponent("agents/a2a-receipts/outcomes.sqlite").path
        do { open = try retainedTasksAwaitingRecovery() }
        catch {
            let detail = "Contact backlog restoration could not read \(source): \(error.localizedDescription). Repair this retained task store, then restart recovery; do not resend accepted messages."
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
                let detail = "Contact backlog restoration could not read \(transcript): \(error.localizedDescription). Repair this conversation and restart recovery; do not resend its messages."
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
                let detail = "Contact backlog restoration could not recover \(transcript): \(error.localizedDescription). Repair the exact queued input, then restart recovery; nothing was resent."
                RepairOwed.owe(dataRoot, id: session, kind: .message, operation: "contact.backlog.restore:" + session,
                    owner: transcript, words: detail, lever: "Repair the queued sender, transcript or attachment named by this failure, then restart NativeAgent.")
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
        // Every backlog is back: contact conversations admit new turns behind it.
        await TurnAdmission.shared.restorationComplete()
        // A task read before this point holds a placeholder: read it again now.
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
        // A restored run nothing resumes gives up its place.
        for task in backlog where !resuming.contains(task.id) {
            await TurnAdmission.shared.withdraw(sessionID: task.canonicalSession!, runID: task.canonicalRunID!)
        }
        restoredInput.removeAll()
    }
}
