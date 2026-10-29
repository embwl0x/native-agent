import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import TurnTrace

// Blueprint: | `AgentConversationFollowups.swift` | Durable queued follow-ups and cancellation |
extension AgentConversationSession {
    /// Queue a follow-up on the thread and start its sender. Nil when the reply
    /// settled in the meantime, so the caller just sends it.
    static func queue(behind row: AgentConversationRecord, name: String, peer: AgentPeerContact?,
                              args: [String: JSONValue], expectsReply: JSONValue?, scope: String, surface: String, dataRoot: URL,
                              perform: @escaping Dispatch) throws -> JSONValue? {
        guard let text = string(args["text"]) else { return nil }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let transport = peer?.transport
        var arguments = args
        arguments["expects_reply"] = expectsReply
        guard let queued = try store.enqueue(id: row.id, text: text,
                byPerson: PersonInitiatedSend.current?.matches(args) == true,
                arguments: arguments,
                stillInFlight: { inFlight($0, transport) }) else { return nil }
        let (saved, item) = queued
        let carried = args.filter { ["session_id", "__session_id"].contains($0.key) }
        _ = AgentConversationRunning.shared.adopt(item.id)
        // A child task keeps this call's context (session, turn envelope, and a
        // person's own send mark), so the queued send clears the same gates later.
        AgentConversationRunning.shared.launch(item.id) {
            await sendWhenSettled(row: row.id, item: item.id, agent: row.agent, label: saved.label, carried: carried,
                                  transport: transport, scope: scope, surface: surface, dataRoot: dataRoot, perform: perform)
        }
        let ahead = (saved.queued ?? []).filter { $0.held == nil && $0.id != item.id }.count
        // What it waits on: the earlier message's card, or a reply still coming.
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
    /// Threads with queued messages no sender in this process is waiting on
    /// (the app restarted): `resumeQueued` picks each up.
    package static func orphanedQueues(dataRoot: URL) -> [AgentConversationRecord] {
        // The same startup pass first settles the sends the restart ended,
        // so what is queued behind them can go.
        settleInterrupted(dataRoot: dataRoot)
        return ((try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []).filter { row in
            (row.queued ?? []).contains { $0.held == nil && !AgentConversationRunning.shared.waiting($0.id) }
                || row.queueReservation.map { !AgentConversationRunning.shared.waiting($0) } == true
        }
    }
    /// After a restart, under the same order and reservation as before: an
    /// unused reservation is let go, a message older than a day or typed by the
    /// person (their send was their own act, which a restart does not carry)
    /// is held with the reason, and the rest get a sender again. `perform`
    /// enters the gated chain below the conversation layer, as the original did.
    package static func resumeQueued(_ row: AgentConversationRecord, dataRoot: URL, perform: @escaping Dispatch) {
        let store = AgentConversationStore(dataRoot: dataRoot)
        if let reserved = row.queueReservation, !AgentConversationRunning.shared.waiting(reserved) {
            _ = try? store.releaseReservation(id: row.id, item: reserved)
        }
        for item in row.queued ?? [] where item.held == nil && AgentConversationRunning.shared.adopt(item.id) {
            if Date().timeIntervalSince(item.queuedAt) >= 24 * 60 * 60 || item.byPerson == true {
                try? store.holdQueued(id: row.id, item: item, reason: item.byPerson == true
                    ? "Not sent: the app restarted before the reply ahead of it settled, and the send was yours to make. Send it again if it is still wanted."
                    : "Not sent: the reply ahead of it did not settle within a day.")
                AgentConversationRunning.shared.release(item.id)
                continue
            }
            let transport = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == row.agent }?.transport
            // The door the thread was asked from, as the row kept it: its sends
            // write it back and carry it on, never this launch's.
            let route = row.replyRoute.map { saved in
                ChatToolSessionContext.ReplyRoute(surface: saved["surface"] ?? row.sourceSurface, destinationId: saved["destinationId"],
                    threadId: saved["threadId"], sourceKey: saved["sourceKey"], replyTo: saved["replyTo"],
                    correlationId: saved["correlationId"], requesterUserId: saved["requesterUserId"])
            }
            AgentConversationRunning.shared.launch(item.id) {
                await ChatToolSessionContext.$replyRoute.withValue(route) {
                    await sendWhenSettled(row: row.id, item: item.id, agent: row.agent, label: row.label, carried: [:],
                                          transport: transport, scope: row.scopeSessionID, surface: row.sourceSurface,
                                          dataRoot: dataRoot, perform: perform)
                }
            }
        }
    }
    /// Sends one queued follow-up once everything ahead of it has settled.
    /// Anything that stops it going is written on the thread, never dropped.
    private static func sendWhenSettled(row id: String, item: String, agent: String, label: String,
                                        carried: [String: JSONValue], transport: AgentPeerTransport?,
                                        scope: String, surface: String, dataRoot: URL, perform: @escaping Dispatch) async {
        defer { AgentConversationRunning.shared.release(item) } // adopted by `queue`
        let store = AgentConversationStore(dataRoot: dataRoot)
        // Register before reading: denials reconcile on read, and replay
        // settlement can land solely in the approval store, even on failure.
        let approvals = await ApprovalLifecycleBus.shared.events()
        let approvalChanges = Task {
            for await event in approvals where event.phase == .resolved || event.phase == .executed {
                AgentConversationRunning.shared.changed()
            }
        }
        defer { approvalChanges.cancel() }
        let queuedAt = (try? store.records().first { $0.id == id })?.queued?.first { $0.id == item }?.queuedAt ?? Date()
        let giveUp = queuedAt.addingTimeInterval(24 * 60 * 60)
        // A reply still being handed to her as a turn goes first, too. Order
        // among queued messages is `takeQueued`'s (only the head, one at a time).
        let ready: (AgentConversationRecord) -> Bool = {
            !replyInFlight($0, transport) && !AgentConversationRunning.shared.watched($0.id) && $0.deliveryState != "delivering"
        }
        while !Task.isCancelled {
            let seen = AgentConversationRunning.shared.seen
            guard let row = try? store.records().first(where: { $0.id == id }),
                  row.queued?.contains(where: { $0.id == item && $0.held == nil }) == true else { return }
            if Date() >= giveUp {
                if let entry = row.queued?.first(where: { $0.id == item }) {
                    try? store.holdQueued(id: id, item: entry, reason: "Not sent: the reply ahead of it did not settle within a day.")
                }
                return
            }
            if let taken = try? store.takeQueued(id: id, item: item, ready: ready) {
                var input = (taken.arguments ?? [:]).merging(carried) { _, current in current }
                input["agent"] = .string(agent)
                input["text"] = .string(taken.text)
                input["conversation"] = .string(label)
                var why = "the conversation did not take it."
                do {
                    let result = try await dispatch(tool: "agent_message", input: input, surface: surface, scope: scope,
                                                    dataRoot: dataRoot, reservation: taken.id, perform: perform)
                    if case .object(let fields) = result, let detail = string(fields["detail"]) { why = detail }
                } catch { why = error.localizedDescription }
                // Still reserved: it never began (refused before its send), so it
                // stays on the thread, held with the reason, and the queue moves on.
                if (try? store.releaseReservation(id: id, item: taken.id)) == true {
                    try? store.holdQueued(id: id, item: taken, reason: "Not sent: " + why)
                }
                return
            }
            // Exact reply settlement writes the store and wakes this waiter.
            await AgentConversationRunning.shared.change(after: seen, until: giveUp)
        }
    }
    /// Stop the reply in flight on this thread, on the lane's own terms, and
    /// join local settlement before reporting what the stop actually did.
    static func cancel(_ previous: AgentConversationRecord?, name: String, peer: AgentPeerContact?, clearQueue: Bool,
                               args: [String: JSONValue], store: AgentConversationStore, dataRoot: URL,
                               perform: Dispatch) async throws -> JSONValue {
        guard let row = previous else {
            return .object(["agent": .string(name), "state": .string("not_opened"), "stopped": .bool(false),
                            "detail": .string("There is no conversation with \(name) here to stop.")])
        }
        let latest = (try? store.records().first { $0.id == row.id }) ?? row
        // A send no process owns any more (a restart mid-send) still counts, so it can be released.
        let orphan = latest.phase == "sending" && ownerless(latest)
        // A message waiting on the person's card is theirs to decide: a stop
        // neither withdraws the card nor releases the conversation from it.
        let awaitingCard: Bool = if case .object(let receipt)? = latest.receipt { receipt["status"] == .string("waiting_approval") } else { false }
        let flying = !awaitingCard && (orphan || replyInFlight(latest, peer?.transport))
        // Admission first: the lane owner's stop runs through agent_cancel's own
        // gate, and nothing here (queue, stop state) changes unless it clears.
        // With nothing in flight it carries no lane target, so it stops nothing.
        var owner: [String: JSONValue] = ["agent": .string(latest.agent)]
        for key in ["session_id", "__session_id"] { owner[key] = args[key] }
        if flying {
            if case .object(let receipt)? = latest.receipt, receipt["terminal"] != .bool(true), let task = string(receipt["task_id"]) {
                owner["task_id"] = .string(task)
            }
            if let message = string(latest.readInput?["message_id"]) { owner["message_id"] = .string(message) }
            if let conversation = latest.conversationID { owner["conversation_id"] = .string(conversation) }
        }
        let result = try await perform("agent_cancel", owner)
        guard case .object(let fields) = result else { return result }
        let state = string(fields["status"]) ?? "cannot_stop"
        guard ["stopped", "stopping", "cannot_stop", "not_here"].contains(state) else { return result } // refused by its gate
        // Withdraw before local cancellation can publish ready and wake queued sends.
        // Keep its result so a failed withdrawal still lets accepted work settle.
        let withdrawal = Result { clearQueue ? try store.clearQueued(id: row.id) : 0 }
        let settled: Result<JSONValue, Error> = await settle {
            let running = AgentConversationRunning.shared
            let stoppedSend = await running.stop(row: latest.id, operation: latest.operationID)
            let retiredWatch = await running.retireWatches(row: latest.id, operation: latest.operationID)
            return Result {
                let cleared = try withdrawal.get()
                let current = try store.records().first { $0.id == row.id } ?? latest
                func answer(_ record: AgentConversationRecord, _ extra: [String: JSONValue]) -> JSONValue {
                    guard case .object(var fields) = AgentConversationView.compact(AgentConversationView.view(record, details: false, dataRoot: dataRoot, includeHistory: false), row: record) else { return .object(extra) }
                    fields.merge(extra) { _, new in new }
                    if cleared > 0 { fields["queue_cleared"] = .int(Int64(cleared)) }
                    return .object(fields)
                }
                if stoppedSend || retiredWatch || stoppedOrReleased(current) {
                    return answer(current, ["stopped": .bool(current.stop?.state == "stopped"),
                        "detail": .string(current.stop?.detail ?? "The reply finished before the stop landed.")])
                }
                if awaitingCard || !orphan && !replyInFlight(current, peer?.transport) {
                    let standing = awaitingCard
                        ? "Your earlier message to \(name) waits on the person's card; a stop does not withdraw a card, and this conversation still waits on it."
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
                    terminal = "released"; detail = "Your ability \(ability) already took the message and has no stop from here; this conversation no longer waits on it, and if \(name) answers, that still lands here."
                } else if [.desktop, .desktopChat].contains(peer?.transport) {
                    terminal = "released"; detail = "Local reply observation is no longer running. The message's remote outcome is unchanged; any answer stays in that chat."
                } else if orphan {
                    terminal = "released"; detail = "No send to \(name) runs here any more (the app restarted mid-send), so it settled as interrupted; this conversation no longer waits on it, and anything \(name) answers still arrives."
                } else if unsettledAttention(current) {
                    terminal = "released"; detail = "Its outcome is not known and \(name)'s route has no stop for it; this conversation no longer waits on it, and anything \(name) answers still arrives."
                } else if liveHandOff(current) {
                    terminal = "released"; detail = "It waits in \(name)'s inbox for its next turn, which has no stop from here; this conversation no longer waits on it, and any answer still comes as a chat of its own."
                } else if peer?.transport == .grokBot {
                    terminal = "released"; detail = "\(name) runs as a routine with no stop from here; this conversation no longer waits on it, and if it answers, that still arrives in the chat that asked."
                } else {
                    terminal = "cannot_stop"; detail = string(fields["detail"]) ?? "\(name)'s route has no stop for a reply already handed over; it keeps working and its answer still arrives."
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
