import MacNerves
import MindCore
import Foundation
import SenseCore
import NativeAgentCore
import PersistenceCore

// Blueprint: | `AgentConversationWaiting.swift` | Checked waits and restart reads settle sends from retained handles or their restart cause. |
extension AgentConversationSession {
    private static let approvalWaitFailureCode = "agent_conversation_approval_unavailable"
    /// Admission precedes the caller's documented retrieval wait; expiry returns evidence without settling execution.
    package static func waitForReply(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, input: [String: JSONValue], scope: String,
        dataRoot: URL, admit: Bool = false,
                             read: @escaping Dispatch) async throws -> JSONValue {
        guard let agent = input["agent"]?.nonblankString else { throw AgentConversationStore.Failure(message: "Name the contact to wait for.") }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let records = Result { try store.records() }
        let pinned = named(input["conversation"]?.nonblankString, agent: agent, scope: scope, rows: try records.get())
        let label = pinned.label
        let exact = input.filter { ["conversation_id", "message_id", "task_id"].contains($0.key) && $0.value != .null && $0.value != .string("") }
        let retained = exact.isEmpty ? nil : try records.get().filter { row in
            row.agent == agent && exact.allSatisfy { key, value in
                key == "conversation_id" ? row.conversationID.map(JSONValue.string) == value : row.readInput?[key] == value
            }
        }.max { $0.updatedAt < $1.updatedAt }
        var readInput = exact
        readInput["agent"] = .string(agent)
        // Retain the selected name so the read resolves the same record.
        if let label { readInput["conversation"] = input["conversation"] ?? .string(label) }
        for key in ["session_id", "__session_id", "details"] { readInput[key] = input[key] }
        if !exact.isEmpty, retained == nil {
            var result = try await read("agent_read", readInput, turn, conversation, mac)
            if case .object(var fields) = result { fields["wait_outcome"] = .string("not_tracked"); result = .object(fields) }
            return result
        }
        let asked: Double
        switch input["seconds"] {
        case nil, .null?: asked = 60
        case .int(let n)? where n > 0 && n <= 300: asked = Double(n)
        case .double(let n)? where n.isFinite && n > 0 && n <= 300: asked = n
        default: throw ToolFailureError("seconds must be positive and at most 300 (default 60).", argumentPath: "seconds", effects: .none)
        }
        let started = Date()
        let deadline = started.addingTimeInterval(asked)
        if let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { "peer:" + $0.id == agent }),
           peer.ability == nil, ChatGPTDotIPCTransport.owns(peer) {
            // The listener marks changes when its reply lands.
            var seen = AgentConversationRunning.shared.seen
            var snapshot = try await read("agent_read", readInput, turn, conversation, mac)
            if readRefused(snapshot) { return snapshot }
            var outcome = "nothing_in_flight"
            while case .object(let fields) = snapshot, case .array(let messages)? = fields["conversation"],
                  let sent = messages.lastIndex(where: {
                      if case .object(let message) = $0 { return message["own"] == .bool(true) }
                      return false
                  }), !messages.dropFirst(sent + 1).contains(where: {
                      if case .object(let message) = $0 { return message["from"] == .string(peer.name) }
                      return false
                  }) {
                outcome = "still_waiting"
                if Date() >= deadline { break }
                await AgentConversationRunning.shared.change(after: seen, until: deadline)
                try Task.checkCancellation()
                if Date() >= deadline { break }
                seen = AgentConversationRunning.shared.seen
                snapshot = try await read("agent_read", readInput, turn, conversation, mac)
                if readRefused(snapshot) { return snapshot }
                outcome = "settled"
            }
            guard case .object(var fields) = snapshot else { return snapshot }
            fields["wait_outcome"] = .string(outcome)
            fields["waited_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
            return .object(fields)
        }
        if admit {
            let first = try await read("agent_read", readInput, turn, conversation.withoutHistory.withoutConsuming, mac)
            if readRefused(first) { return first }
        }
        let transport = try AgentPeerStore(dataRoot: dataRoot).list().first { "peer:" + $0.id == agent }?.transport
        var outcome = "nothing_in_flight"
        var latest: AgentConversationRecord?
        // While this watches, a reply that lands comes back here, not as a second turn.
        var watching: String?
        // Once the watch ends, the news takes a held answer this wait did not deliver.
        defer { HeldSends.publish(dataRoot: dataRoot) }
        defer { if let watching { AgentConversationRunning.shared.unwatch(watching) } }
        while !Task.isCancelled {
            let seen = AgentConversationRunning.shared.seen
            let rows = try store.records()
            guard let row = try (retained?.id ?? pinned.record?.id).flatMap({ id in rows.first { $0.id == id } })
                    ?? (retained == nil ? store.find(scopeSessionID: scope, agent: agent, label: label, in: rows) : nil),
                  retained == nil || row.operationID == retained?.operationID else { outcome = "not_opened"; break }
            latest = row
            if watching == nil { watching = row.id; AgentConversationRunning.shared.watch(row.id) }
            guard try replyInFlight(row, transport, dataRoot: dataRoot)
                    || !stoppedOrReleased(row) && heldReplyPending(row, dataRoot: dataRoot) else {
                if outcome != "nothing_in_flight" { outcome = "settled" }
                break
            }
            outcome = "still_waiting"
            if Date() >= deadline { break }
            await AgentConversationRunning.shared.change(after: seen, until: deadline)
        }
        if Task.isCancelled { outcome = "cancelled" }
        // A held send's answer this wait returns reaches the turn in its tool result, said while it still watches.
        if let latest, watching != nil { store.held.carry(latest.operationID) }
        // A reply handed to this wait just before it gave up is in the row: stop watching under the store's lock and take the row as it is
        // then, so that reply is returned here and never falls between this wait and a turn of its own. A row that cannot be updated keeps
        // the last snapshot.
        let gaveUp = ["still_waiting", "cancelled"].contains(outcome)
        if gaveUp, let row = latest, let id = watching {
            let released = try? store.update(id: row.id, operationID: row.operationID, touch: false) { _ in
                AgentConversationRunning.shared.unwatch(id)
            }
            if let current = released {
                watching = nil
                latest = current
                if outcome == "still_waiting", try !(replyInFlight(current, transport, dataRoot: dataRoot)
                    || !stoppedOrReleased(current) && heldReplyPending(current, dataRoot: dataRoot)) { outcome = "settled" }
            }
        }
        // Out of time (or stopped): the row as the release left it, never another read that could hold the turn past `seconds` or find the
        // conversation already moved on to its next message.
        let snapshot: JSONValue?
        if gaveUp, let latest {
            snapshot = AgentConversationView.view(latest, details: input["details"] == .bool(true), dataRoot: dataRoot, includeHistory: false)
        } else {
            snapshot = try await read("agent_read", readInput, turn, conversation.withoutHistory.withoutConsuming, mac)
        }
        guard case .object(var fields)? = snapshot else { return .object(["wait_outcome": .string(outcome)]) }
        // Claim only the exact routine answer returned by this wait; stopped or timed-out waits cannot consume it.
        if transport == .grokBot, ["settled", "nothing_in_flight"].contains(outcome), !Task.isCancelled,
           let delivered = fields["reply"]?.nonblankString, let latest, agent.hasPrefix("peer:"),
           let message = latest.readInput?["message_id"]?.nonblankString {
            let clipped = fields["reply_truncated"] == .bool(true)
            try GrokRequestStore(dataRoot: dataRoot).shown(message, peer: String(agent.dropFirst(5)), by: "wait") {
                $0 == delivered || (clipped && $0.hasPrefix(delivered))
            }
        }
        // Wait returns the exchange without duplicating retained history.
        if agent.hasPrefix("peer:"), let latest,
           case .object(let shown) = AgentConversationView.compact(.object(fields), row: latest) {
            fields = shown
        }
        fields["wait_outcome"] = .string(outcome)
        fields["waited_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
        let detail = switch outcome {
        case "settled": "The reply in flight settled while you waited; this is the conversation now."
        case "still_waiting": "Still in flight when the wait ran out; nothing was resent. Wait again, or carry on: the answer still arrives."
        case "not_opened": "There is no conversation with that contact here to wait on."
        case "cancelled": "The wait was stopped."
        default: "Nothing was in flight on this conversation, so there was nothing to wait for."
        }
        fields["wait_detail"] = .string(detail)
        return .object(fields)
    }
    /// The thread is occupied: its reply is still coming, or a queued message is ahead (waiting or taken to go next). A new message queues behind.
    static func inFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?, dataRoot: URL) throws -> Bool {
        try replyInFlight(row, transport, dataRoot: dataRoot) || AgentConversationRunning.shared.watched(row.id) || row.queueReservation != nil
            || row.queued?.contains(where: { $0.held == nil || $0.waitingForMac == true }) == true
    }
    /// What a person's own send waits behind: a reply in flight, a watch, a reservation or an ordinary queued send, never a send held for the Mac.
    static func inFlightAheadOfPerson(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?, dataRoot: URL) throws -> Bool {
        try replyInFlight(row, transport, dataRoot: dataRoot) || AgentConversationRunning.shared.watched(row.id) || row.queueReservation != nil
            || row.queued?.contains(where: { $0.held == nil }) == true
    }
    /// Admission owns a send before its task registers; only process-exit evidence can abandon that interval.
    static func replyInFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?, dataRoot: URL) throws -> Bool {
        if row.phase == "sending" { return !ownerless(row) }
        if try unsettledAttentionChecked(row, dataRoot: dataRoot) { return true }
        guard row.phase == "waiting" else { return false }
        // Process-owned desktop and background watches cannot survive restart.
        if transport == .desktop || backgroundSend(row) { return !stoppedOrReleased(row) && AgentConversationRunning.shared.routeWatching(row: row.id,
            operation: row.operationID) }
        // Other lanes settle through their own receipt or stop.
            return !stoppedOrReleased(row)
    }
    /// Background sends hold the thread only while their owning task watches them.
    static func backgroundSend(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "waiting", case .object(let receipt)? = row.receipt else { return false }
        return receipt["background_send"] == .bool(true)
    }
    static func settleInterrupted(dataRoot: URL,
        read: (AgentConversationRecord, AgentPeerContact) async throws -> JSONValue) async throws {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let running = AgentConversationRunning.shared
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let desktop = Set(peers.filter { $0.transport == .desktop }.map { "peer:" + $0.id })
        func orphaned(_ row: AgentConversationRecord) throws -> Bool {
            if backgroundSend(row) { return !running.routeWatching(row: row.id, operation: row.operationID) }
            guard ownerless(row) else { return false }
            // Desktop watches belong to their sending process; other lanes retain their own restart evidence.
            if row.phase == "waiting" { return desktop.contains(row.agent) && !running.routeWatching(row: row.id, operation: row.operationID) }
            return try row.phase == "sending" || unsettledAttentionChecked(row, dataRoot: dataRoot) && !awaitingApproval(row)
        }
        let rows = try store.records()
        let newest = Dictionary(rows.compactMap { row in row.operationStartedAt.map { (row.agent, $0) } }, uniquingKeysWith: { max($0, $1) })
        func reached(_ row: AgentConversationRecord) {
            guard row.agent.hasPrefix("peer:"), let started = row.operationStartedAt, newest[row.agent] == started else { return }
            AgentPeerStore(dataRoot: dataRoot).clearUnavailable(peerID: String(row.agent.dropFirst(5)), since: started)
        }
        for row in rows {
            do {
                let peer = peers.first { "peer:" + $0.id == row.agent && AgentConversationStore.sameRoute(row.peerRouteFingerprint, $0) }
                if let peer, [.a2a, .nativeAgent].contains(peer.transport), let input = row.readInput,
                   (peer.transport == .a2a ? input["task_id"]?.nonblankString != nil
                    : input["message_id"]?.nonblankString != nil && input["conversation_id"]?.nonblankString != nil),
                   try orphaned(row) || ownerless(row) && row.phase == "waiting" && row.automaticRead {
                    _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                        guard try orphaned($0) || ownerless($0) && $0.phase == "waiting" && $0.automaticRead else { return }
                        if $0.phase == "sending" {
                            $0.receipt = .object(["status": .string("waiting"), "sent": .null, "completed": .bool(false),
                                "delivery": .string("unconfirmed")])
                        } else if case .object(var fields)? = $0.receipt {
                            fields["background_send"] = nil; $0.receipt = .object(fields)
                        }
                        $0.phase = "waiting"; $0.automaticRead = true; $0.nextReadAt = Date()
                    }
                    reached(row)
                    continue
                }
                guard try orphaned(row) else { continue }
                reached(row)
                let exchange = row.exchanges?.last(where: { $0.id == row.operationID })
                let cause = peer?.transport == .acp || peer?.transport == .mcpHost
                    ? "The app restarted while \(row.name) was answering and its run ended with it."
                    : "The app restarted and stopped watching for \(row.name)'s answer, which can no longer be read here."
                var receipt: JSONValue = .object(["status": .string("failed"), "sent": .null, "delivery": .string("failed"),
                    "completed": .bool(false), "terminal": .bool(true), "detail": .string(
                        cause + "\nYou sent:\n" + (exchange?.prompt ?? "The sent words were not retained.")
                        + "\nNothing was resent.")])
                if let peer, peer.transport == .acp, row.conversationID != nil {
                    let replay: JSONValue?
                    do { replay = try await read(row, peer) }
                    catch is CancellationError { throw CancellationError() }
                    catch { replay = nil }
                    try Task.checkCancellation()
                    if let replay, case .object(let fields) = replay, !readRefused(replay),
                       let exchange, let prompt = exchange.prompt, !prompt.isEmpty, let replayedPrompt = fields["prompt"]?.nonblankString,
                       replayedPrompt.hasSuffix(prompt) || exchange.promptTruncated && replayedPrompt.hasPrefix(prompt) {
                        if let text = AgentConversationExchange.answer(fields).text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            receipt = try await store.retainReply(replay, for: row)
                            _ = try record(receipt, for: row, store: store, peer: peer, background: backgroundSend(row))
                        } else {
                            receipt = .object(["status": .string("failed"), "sent": .null, "delivery": .string("delivered"),
                                "completed": .bool(false), "terminal": .bool(true), "detail": .string("""
                                    \(row.name) received your message: its session shows it. The app restarted before it answered, and \
                                    its run ended with it.\nYou sent:\n\(prompt)\nNothing was resent. The message is in \(row.name)'s \
                                    session: ask it to continue in this conversation instead of sending the message again.
                                    """)])
                        }
                    }
                }
                _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                    if try orphaned($0) { absorb(receipt, into: &$0) }
                    guard $0.phase != "sending", $0.phase != "waiting" else { return }
                    if $0.agent.hasPrefix("peer:"), $0.personInitiated != true {
                        $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
                    }
                }
            } catch let failure as ToolFailureError where failure.code == approvalWaitFailureCode {
                // The missing/unreadable approval belongs to this send. Its owner has recorded a named repair; unrelated queues resume.
                nativeLog("Conversation %@ remains held: %@", row.id, failure.localizedDescription)
            }
        }
    }
    /// Use process start time as well as liveness: a current send can briefly precede its live registration.
    static func ownerless(_ row: AgentConversationRecord) -> Bool {
        row.operationStartedAt.map { $0 < AbandonedTurnReconciler.processEpoch } == true
            && !AgentConversationRunning.shared.live(row: row.id, operation: row.operationID)
    }
    /// Unknown dispatched outcomes fence the thread while their call is live; executable approvals fence it until terminal evidence or explicit
    /// cancellation. This projection cannot replace the checked approval owner used by executable waits.
    package static func unsettledAttention(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "attention", !stoppedOrReleased(row), case .object(let root)? = row.receipt else { return false }
        let value = row.sendEvidence
        if root["sent"] == .bool(false) || value["sent"] == .bool(false) { return false }
        let status = value["run_status"]?.nonblankString ?? value["status"]?.nonblankString ?? ""
        // Unknown outcomes hold the thread only while their owning call can still produce a reply: a call that ended produces none.
        return ["outcome_unknown", "delivery_unknown"].contains(status) && value["terminal"] != .bool(true)
                && AgentConversationRunning.shared.live(row: row.id, operation: row.operationID)
            || AgentConversationRecord.approvalWaits(status)
    }
    /// Retain an approved exchange’s place ahead of its queue until replay claims it; terminal approval evidence releases it.
    static func unsettledAttentionChecked(_ row: AgentConversationRecord, dataRoot: URL) throws -> Bool {
        guard unsettledAttention(row) else { return false }
        let value = row.sendEvidence
        let status = value["run_status"]?.nonblankString ?? value["status"]?.nonblankString ?? ""
        if AgentConversationRecord.approvalWaits(status), case .object(let root)? = row.receipt {
            let operation = "agent.approval-wait:" + row.operationID
            let approval = value["approvalId"]?.nonblankString ?? root["approvalId"]?.nonblankString
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            do {
                guard let approval, !approval.isEmpty else {
                    throw AgentConversationStore.Failure(message: "The retained receipt has no approval identity.")
                }
                let settled = try inbox.decisionSettledUnlocked(approval)
                RepairOwed.settle(dataRoot, operation: operation,
                    evidence: .init(source: "approval", id: approval))
                return !settled
            } catch {
                let owner = approval == nil ? AgentConversationStore(dataRoot: dataRoot).fileURL.path : inbox.approvalsPath.path
                let words = "Conversation \(row.id), operation \(row.operationID), approval \(approval ?? "identity unavailable"): "
                    + error.localizedDescription + " The send remains held; its outcome is unproven."
                let lever = "Repair this send's exact approval evidence, then read the conversation again; do not resend it to repair bookkeeping."
                RepairOwed.owe(dataRoot, id: row.operationID + ":approval", kind: .message,
                    evidence: [.init(source: "agents/conversations", id: row.id)],
                    operation: operation, owner: owner, words: words, lever: lever)
                throw ToolFailureError(words, effects: .unknown, owner: owner,
                    code: approvalWaitFailureCode, instruction: lever, recovery: .reconcile)
            }
        }
        return true
    }
    /// Approval lifecycle events wake queues when a decision or replay receipt commits.
    static func awaitingApproval(_ row: AgentConversationRecord) -> Bool {
        guard unsettledAttention(row) else { return false }
        let value = row.sendEvidence
        return AgentConversationRecord.approvalWaits(value["run_status"]?.nonblankString ?? value["status"]?.nonblankString ?? "")
    }
    /// Cancellation settles the local wait; a retired desktop reader leaves late remote answers in their chat.
    package static func stoppedOrReleased(_ row: AgentConversationRecord) -> Bool {
        guard let stop = row.stop, stop.operationID == row.operationID else { return false }
        return ["stopped", "released"].contains(stop.state)
    }
}
