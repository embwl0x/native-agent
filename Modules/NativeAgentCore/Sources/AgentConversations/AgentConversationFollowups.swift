import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import StandingBots
import TurnTrace
import MacControl

/// Hand the driver's settlement form to cleanup without relying on task inheritance.
package func withAgentMacDriver<Value>(_ mac: MacOperationContext, driver: MacDriverBinding?,
    operation: (MacOperationContext) throws -> Value) rethrows -> Value {
    var mac = mac
    mac.driver = driver
    return try operation(mac)
}

package func withAgentMacDriver<Value>(_ mac: MacOperationContext, driver: MacDriverBinding?,
    isolation: isolated (any Actor)? = #isolation,
    operation: (MacOperationContext) async throws -> Value) async rethrows -> Value {
    var mac = mac
    mac.driver = driver
    return try await operation(mac)
}

// Blueprint: | `AgentConversationFollowups.swift` | Queued sends retain order, authority and settlement. |
extension AgentConversationSession {
    /// A reply that settled meanwhile needs no queue entry; the caller can send directly.
    static func queue(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
        behind row: AgentConversationRecord, name: String, peer: AgentPeerContact?,
                              args: [String: JSONValue], expectsReply: JSONValue?, scope: String, surface: String, dataRoot: URL,
                              perform: @escaping Dispatch) throws -> JSONValue? {
        guard let text = string(args["text"]) else { return nil }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let transport = peer?.transport
        var arguments = args
        arguments["expects_reply"] = expectsReply
        guard let queued = try store.enqueue(id: row.id, scopeSessionID: scope, text: text,
                byPerson: turn.personInitiatedSend?.matches(args) == true,
                arguments: arguments,
                stillInFlight: { try inFlight($0, transport, dataRoot: dataRoot) }) else { return nil }
        let (saved, item) = queued
        let carried = args.filter { ["session_id", "__session_id"].contains($0.key) }
        _ = AgentConversationRunning.shared.adopt(item.id)
        // Preserve the initiating task context so the queued send clears the same gates later.
        AgentConversationRunning.shared.launch(item.id) {
            await sendWhenSettled(turn: turn, mac: mac, conversation: conversation, workspace: workspace, row: row.id, item: item.id,
                agent: row.agent, carried: carried,
                                  transport: transport, scope: scope, surface: surface, dataRoot: dataRoot, perform: perform)
        }
        guard let current = try store.records().first(where: { $0.id == saved.id }) else {
            throw AgentConversationStore.Failure(message: "The accepted queue's conversation is missing; inspect its saved record before another send.")
        }
        if let reason = current.queued?.first(where: { $0.id == item.id })?.notSentReason {
            return notSent(name, label: current.label, reason, item: item.id)
        }
        let ahead = (saved.queued ?? []).filter { $0.held == nil && $0.id != item.id }.count
        let awaitingCard: Bool = if case .object(let receipt)? = saved.receipt { receipt["status"] == .string("waiting_approval") } else { false }
        let blocker = awaitingCard ? "your earlier message to \(name), which waits on the person's card" : "the reply in progress from \(name)"
        let lever = awaitingCard ? "It goes by itself once that card is decided, approved or not; agent_cancel {clear_queue: true} withdraws it."
            : "It goes by itself, in order, when that reply settles; agent_cancel stops the reply in progress."
        return .object(["agent": .string(name), "agent_id": .string(row.agent), "conversation": .string(saved.label),
            "state": .string("queued"), "queued": .bool(true), "sent": .bool(false), "queued_id": .string(item.id),
            "queue_position": .int(Int64(ahead + 1)),
            "detail": .string("Queued behind \(blocker)" + (ahead > 0 ? " and \(ahead) earlier queued message\(ahead == 1 ? "" : "s")" : "")
                + ". Do not send it again. " + lever)])
    }
    package static func orphanedQueues(dataRoot: URL) throws -> [AgentConversationRecord] {
        // Settle restart-interrupted sends before releasing follow-ups queued behind them.
        try settleInterrupted(dataRoot: dataRoot)
        return try AgentConversationStore(dataRoot: dataRoot).records().filter { row in
            (row.queued ?? []).contains { ($0.held == nil || $0.waitingForMac == true) && !AgentConversationRunning.shared.waiting($0.id) }
                || row.queueReservation.map { !AgentConversationRunning.shared.waiting($0) } == true
        }
    }
    /// Restart cannot carry a person’s own send authority. Other sends retain their original gated chain, order and reservation.
    package static func resumeQueued(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
        _ row: AgentConversationRecord, dataRoot: URL, afterRestart: Bool = true, perform: @escaping Dispatch) {
        let store = AgentConversationStore(dataRoot: dataRoot)
        do {
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let transport = peers.first { "peer:" + $0.id == row.agent }?.transport
        if row.agent.hasPrefix("peer:"), transport == nil {
            throw AgentConversationStore.Failure(message: """
                Queued conversation \(row.id) names a contact not present in the checked address book. Resolve its identity before resuming; no \
                message was sent.
                """)
        }
        if let reserved = row.queueReservation, !AgentConversationRunning.shared.waiting(reserved) {
            _ = try store.releaseReservation(id: row.id, item: reserved)
        }
        for item in row.queued ?? [] where (item.held == nil || item.waitingForMac == true) && AgentConversationRunning.shared.adopt(item.id) {
            if afterRestart && item.byPerson == true {
                defer { AgentConversationRunning.shared.release(item.id) }
                try store.refuseQueued(id: row.id, item: item, reason:
                    "Not sent: the app restarted before this send began. It was yours to make; send it again if it is still wanted.")
                continue
            }
            // Keep the asking door recorded on the row, rather than substituting this launch’s identity. The send resumes for its own caller;
            // an item saved without one was queued by the row's caller.
            let route = row.replyRoute.map { saved in
                ChatToolSessionContext.ReplyRoute(surface: saved["surface"] ?? row.sourceSurface, destinationId: saved["destinationId"],
                    threadId: saved["threadId"], sourceKey: saved["sourceKey"], replyTo: saved["replyTo"],
                    correlationId: saved["correlationId"], requesterUserId: saved["requesterUserId"])
            }
            let resumed = turn.with(\.envelope, turn.envelope.map { $0.withDeliveryRoute(route) })
            AgentConversationRunning.shared.launch(item.id) {
                    await sendWhenSettled(turn: resumed, mac: mac, conversation: conversation, workspace: workspace, row: row.id, item: item.id,
                        agent: row.agent, carried: [:],
                                          transport: transport, scope: item.scopeSessionID ?? row.scopeSessionID, surface: row.sourceSurface,
                                          dataRoot: dataRoot, perform: perform)
            }
        }
        } catch { queueReadFailed(error, row: row.id, dataRoot: dataRoot) }
    }
    /// Owner changes release the queue; a refusal settles before releasing its place.
    private static func sendWhenSettled(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
        row id: String, item: String, agent: String,
                                        carried: [String: JSONValue], transport: AgentPeerTransport?,
                                        scope: String, surface: String, dataRoot: URL, perform: @escaping Dispatch) async {
        defer { AgentConversationRunning.shared.release(item) } // adopted by `queue`
        let store = AgentConversationStore(dataRoot: dataRoot)
        // Register before reading or releasing so restart-while-away cannot miss the edge; observers live only with this sender.
        let presence = NotificationCenter.default.addObserver(forName: MacPersonInput.presenceChanged, object: nil, queue: nil) { note in
            if note.userInfo?["signal"] as? String == "person.away" { AgentConversationStore.release(dataRoot: dataRoot) }
        }
        let drivers = await MacAttentionSessionStore.shared.driverChanges()
        let driverChanges = Task {
            for await _ in drivers {
                AgentConversationStore.release(dataRoot: dataRoot)
            }
        }
        defer { NotificationCenter.default.removeObserver(presence); driverChanges.cancel() }
        MacPersonInput.startPresenceWakes()
        AgentConversationStore.release(dataRoot: dataRoot)
        // Register before reading because denial and replay settlement can land solely in approval storage.
        let approvals = await ApprovalLifecycleBus.shared.events()
        let approvalChanges = Task {
            for await event in approvals where event.phase == .resolved || event.phase == .executed {
                AgentConversationRunning.shared.changed()
            }
        }
        defer { approvalChanges.cancel() }
        // Reply handover precedes queued sends; only the queue head may run.
        let ready: (AgentConversationRecord) throws -> Bool = {
            try !replyInFlight($0, transport, dataRoot: dataRoot) && !AgentConversationRunning.shared.watched($0.id) && $0.deliveryState != "delivering"
        }
        do {
        while !Task.isCancelled {
            let seen = AgentConversationRunning.shared.seen
            guard let row = try store.records().first(where: { $0.id == id }) else {
                throw AgentConversationStore.Failure(message: "The queued message's conversation is missing; its outcome is unproven.")
            }
            guard row.queued?.contains(where: { $0.id == item && ($0.held == nil || $0.waitingForMac == true) }) == true else { return }
            if let taken = try store.takeQueued(id: id, item: item, ready: ready) {
                var input = (taken.arguments ?? [:]).merging(carried) { _, current in current }
                input["agent"] = .string(agent)
                input["text"] = .string(taken.text)
                input["conversation"] = .string(id)
                let why: String
                do {
                    let result = try await withAgentMacDriver(mac, driver: nil) { mac in
                        try await dispatch(turn: turn, mac: mac, conversation: conversation, workspace: workspace, tool: "agent_message", input: input,
                            surface: surface, scope: scope,
                                           dataRoot: dataRoot, reservation: taken.id, perform: perform)
                    }
                    if case .object(let fields) = result, let detail = string(fields["detail"]) { why = detail }
                    else { why = "The call returned without a reason; this reservation's send never began." }
                } catch { why = error.localizedDescription }
                // The reservation proves this send never began; save its terminal reason and release its place together.
                try store.refuseQueued(id: id, item: taken, reason: "Not sent: " + why, reserved: true)
                // A takeover before Return returns this exact send to its one sender.
                if try store.records().first(where: { $0.id == id })?.queued?.contains(where: { $0.id == item && ($0.waitingForMac == true
                    || $0.held == nil) }) == true {
                    continue
                }
                return
            }
            await AgentConversationRunning.shared.change(after: seen)
        }
        } catch { queueReadFailed(error, row: id, dataRoot: dataRoot) }
    }

    package static func queueReadFailed(_ error: Error, row: String, dataRoot: URL) {
        RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .message,
            operation: "agent.queue:" + row, owner: dataRoot.appendingPathComponent("agents/conversations.json").path,
            words: "Queued contact work could not be read or settled: " + error.localizedDescription
                + ". Accepted messages remain in their conversation; none was resent.",
            lever: "Repair the named conversation/contact storage, then resume the retained queue.")
    }
    /// Stop through the lane owner and join settlement before reporting its actual result.
    static func cancel(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, _ previous: AgentConversationRecord?, name: String,
        peer: AgentPeerContact?, clearQueue: Bool,
                               args: [String: JSONValue], store: AgentConversationStore, dataRoot: URL,
                               perform: Dispatch) async throws -> JSONValue {
        guard let row = previous else {
            return .object(["agent": .string(name), "state": .string("not_opened"), "stopped": .bool(false),
                            "detail": .string("There is no conversation with \(name) here to stop.")])
        }
        guard let latest = try store.records().first(where: { $0.id == row.id }) else {
            throw AgentConversationStore.Failure(
                message: "The current conversation is unavailable; nothing was stopped. Read the contact again before requesting Stop.")
        }
        guard latest.scopeSessionID == row.scopeSessionID, latest.operationID == row.operationID else {
            throw AgentConversationStore.Failure(
                message: "The displayed send has moved on; its newer send was not stopped. Read the contact again before requesting Stop.")
        }
        // Restart-interrupted sends remain releasable even without a live process.
        let orphan = latest.phase == "sending" && ownerless(latest)
        // A message waiting on the person's card is theirs to decide: a stop neither withdraws the card nor releases the conversation from it.
        let awaitingCard: Bool = if case .object(let receipt)? = latest.receipt { receipt["status"] == .string("waiting_approval") } else { false }
        let flying = try !awaitingCard && (orphan || replyInFlight(latest, peer?.transport, dataRoot: dataRoot))
        // Gate the lane stop before changing queue or stop state; no in-flight target means no lane cancellation.
        var owner: [String: JSONValue] = ["agent": .string(latest.agent)]
        for key in ["session_id", "__session_id"] { owner[key] = args[key] }
        if flying {
            if case .object(let receipt)? = latest.receipt, receipt["terminal"] != .bool(true), let task = string(receipt["task_id"]) {
                owner["task_id"] = .string(task)
            }
            if let message = string(latest.readInput?["message_id"]) { owner["message_id"] = .string(message) }
            if let conversation = latest.conversationID { owner["conversation_id"] = .string(conversation) }
        }
        let result = try await perform("agent_cancel", owner, turn, conversation, mac)
        guard case .object(let fields) = result else { return result }
        let state = string(fields["status"]) ?? "cannot_stop"
        guard ["stopped", "stopping", "cannot_stop", "not_here"].contains(state) else { return result } // refused by its gate
        // Withdraw before local cancellation can publish ready and wake queued sends. Keep its result so a failed withdrawal still lets accepted work settle.
        let withdrawal = Result { clearQueue ? try store.clearQueued(id: row.id) : 0 }
        let settled: Result<JSONValue, Error> = await settle {
            let running = AgentConversationRunning.shared
            let stoppedSend = await running.stop(row: latest.id, operation: latest.operationID)
            let retiredWatch = await running.retireWatches(row: latest.id, operation: latest.operationID)
            return Result {
                let cleared = try withdrawal.get()
                guard let current = try store.records().first(where: { $0.id == row.id }) else {
                    throw AgentConversationStore.Failure(
                        message: "Stop ran, but the current conversation could not be found for settlement. Inspect the contact before another action.")
                }
                func answer(_ record: AgentConversationRecord, _ extra: [String: JSONValue]) -> JSONValue {
                    guard case .object(var fields) = AgentConversationView.compact(AgentConversationView.view(record, details: false,
                        dataRoot: dataRoot, includeHistory: false), row: record) else { return .object(extra) }
                    fields.merge(extra) { _, new in new }
                    if cleared > 0 { fields["queue_cleared"] = .int(Int64(cleared)) }
                    return .object(fields)
                }
                if stoppedSend || retiredWatch || stoppedOrReleased(current) {
                    return answer(current, ["stopped": .bool(current.stop?.state == "stopped"),
                        "detail": .string(current.stop?.detail ?? "The reply finished before the stop landed.")])
                }
                if try awaitingCard || !orphan && !replyInFlight(current, peer?.transport, dataRoot: dataRoot) {
                    let standing = awaitingCard
                        ? """
                            Your earlier message to \(name) waits on the person's card; a stop does not withdraw a card, and this conversation \
                            still waits on it.
                            """
                        : "Nothing from \(name) is in flight on this conversation, so there was nothing to stop."
                    return answer(current, ["stopped": .bool(false), "detail": .string(standing + (cleared > 0 ? " The queued messages were withdrawn." : ""))])
                }
                if state == "stopping" {
                    return answer(current, ["stopped": .bool(false), "detail": fields["detail"] ?? .string("The remote stop has not finished.")])
                }
                let detail: String
                let terminal: String
                if state == "stopped" { terminal = "stopped"; detail = string(fields["detail"]) ?? "" }
                else if let ability = peer?.ability {
                    terminal = "released"; detail = """
                        Your ability \(ability) already took the message and has no stop from here; this conversation no longer waits on it, and if \
                        \(name) answers, that still lands here.
                        """
                } else if [.desktop, .desktopChat].contains(peer?.transport) {
                    terminal = "released"; detail = """
                        Local reply observation is no longer running. The message's remote outcome is unchanged; any answer stays in that chat.
                        """
                } else if orphan {
                    terminal = "released"; detail = """
                        No send to \(name) runs here any more (the app restarted mid-send), so it settled as interrupted; this conversation no \
                        longer waits on it, and anything \(name) answers still arrives.
                        """
                } else if try unsettledAttentionChecked(current, dataRoot: dataRoot) {
                    terminal = "released"; detail = """
                        Its outcome is not known and \(name)'s route has no stop for it; this conversation no longer waits on it, and anything \
                        \(name) answers still arrives.
                        """
                } else if peer?.transport == .grokBot {
                    terminal = "released"; detail = """
                        \(name) runs as a routine with no stop from here; this conversation no longer waits on it, and if it answers, that still \
                        arrives in the chat that asked.
                        """
                } else {
                    terminal = "cannot_stop"; detail = string(fields["detail"])
                        ?? "\(name)'s route has no stop for a reply already handed over; it keeps working and its answer still arrives."
                }
                let saved = try store.update(id: current.id, operationID: latest.operationID) {
                    if stoppedOrReleased($0) || $0.phase == "ready" { return }
                    if orphan, $0.phase == "sending" { interrupted(&$0) }
                    $0.stop = AgentConversationStop(state: terminal, operationID: latest.operationID, at: Date(), detail: detail)
                    if terminal != "cannot_stop" { $0.phase = "ready"; $0.automaticRead = false; $0.nextReadAt = nil }
                    if case .object(var receipt)? = $0.receipt {
                        receipt["detail"] = .string(detail)
                        if terminal == "stopped" {
                            receipt["status"] = .string("cancelled"); receipt["completed"] = .bool(false); receipt["terminal"] = .bool(true)
                            if let task = fields["task"] { receipt["cancel_receipt"] = task }
                        }
                        $0.receipt = AgentConversationStore.cacheReceipt(.object(receipt))
                    }
                }
                return answer(saved, ["stopped": .bool(saved.stop?.state == "stopped"),
                    "detail": .string(saved.stop?.detail ?? "The reply finished before the stop landed.")])
            }
        }
        do { return try settled.get() }
        catch var failure as AgentConversationStore.Failure { failure.effects = .unknown; throw failure }
    }
}
