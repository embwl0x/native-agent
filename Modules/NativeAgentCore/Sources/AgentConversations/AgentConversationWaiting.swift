import MacControl
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

// Blueprint: | `AgentConversationWaiting.swift` | Waits preserve checked approval and restart evidence. |
extension AgentConversationSession {
    private static let approvalWaitFailureCode = "agent_conversation_approval_unavailable"
    /// Admission precedes the caller's documented retrieval wait; expiry returns evidence without settling execution.
    package static func waitForReply(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, input: [String: JSONValue], scope: String,
        dataRoot: URL, admit: Bool = false,
                             read: @escaping Dispatch) async throws -> JSONValue {
        guard let agent = string(input["agent"]) else { throw AgentConversationStore.Failure(message: "Name the contact to wait for.") }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let records = Result { try store.records() }
        let pinned = named(string(input["conversation"]), agent: agent, scope: scope, rows: try records.get())
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
                    || !stoppedOrReleased(row) && heldReplyPending(row) else {
                if outcome != "nothing_in_flight" { outcome = "settled" }
                break
            }
            outcome = "still_waiting"
            if Date() >= deadline { break }
            await AgentConversationRunning.shared.change(after: seen, until: deadline)
        }
        if Task.isCancelled { outcome = "cancelled" }
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
                    || !stoppedOrReleased(current) && heldReplyPending(current)) { outcome = "settled" }
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
           let delivered = string(fields["reply"]), let latest, agent.hasPrefix("peer:"),
           let message = string(latest.readInput?["message_id"]) {
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
    /// Before resuming queues, settle sends begun before this process as interrupted; restart never authorizes resending.
    static func settleInterrupted(dataRoot: URL) throws {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let running = AgentConversationRunning.shared
        let desktop = Set(try AgentPeerStore(dataRoot: dataRoot).list().filter { $0.transport == .desktop }.map { "peer:" + $0.id })
        func orphaned(_ row: AgentConversationRecord) throws -> Bool {
            if backgroundSend(row) { return !running.routeWatching(row: row.id, operation: row.operationID) }
            guard ownerless(row) else { return false }
            // Desktop watches belong to their sending process; other lanes retain their own restart evidence.
            if row.phase == "waiting" { return desktop.contains(row.agent) && !running.routeWatching(row: row.id, operation: row.operationID) }
            return try row.phase == "sending" || unsettledAttentionChecked(row, dataRoot: dataRoot) && !awaitingApproval(row)
        }
        // An old row keeps its time (a phase change still moves it); the agent is told, in the chat that sent it, what the restart did to its send.
        for row in try store.records() {
            do {
                guard try orphaned(row) else { continue }
                _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                    guard try orphaned($0) else { return }
                    interrupted(&$0)
                    if $0.agent.hasPrefix("peer:"), $0.personInitiated != true {
                        $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
                    }
                }
            } catch let failure as ToolFailureError where failure.code == approvalWaitFailureCode {
                // The missing/unreadable approval belongs to this send. Its owner has recorded a named repair; unrelated queues resume.
                nativeLog("Conversation %@ remains held: %@", row.id, failure.localizedDescription)
            }
        }
        // An interrupted newest send may clear only an unavailable mark written since it began; newer genuine faults remain.
        let peers = AgentPeerStore(dataRoot: dataRoot)
        let newest = try Dictionary(store.records().filter { $0.agent.hasPrefix("peer:") }
            .map { row -> (String, (row: AgentConversationRecord, startedAt: Date)) in
                guard let startedAt = row.operationStartedAt else {
                    throw AgentConversationStore.Failure(
                        message: "Conversation \(row.id) has no operation start time; repair its retained evidence before ordering interrupted sends.")
                }
                return (row.agent, (row: row, startedAt: startedAt))
            }) {
                a, b in a.startedAt >= b.startedAt ? a : b
            }
        for (agent, send) in newest {
            guard case .object(let receipt)? = send.row.receipt, receipt["status"] == .string("interrupted") else { continue }
            peers.clearUnavailable(peerID: String(agent.dropFirst(5)), since: send.startedAt)
        }
    }
    /// Use process start time as well as liveness: a current send can briefly precede its live registration.
    static func ownerless(_ row: AgentConversationRecord) -> Bool {
        row.operationStartedAt.map { $0 < AbandonedTurnReconciler.processEpoch } == true
            && !AgentConversationRunning.shared.live(row: row.id, operation: row.operationID)
    }
    /// Process exit ends the local turn without proving a reply or authorizing a resend.
    package static func restartDetail(_ name: String) -> String {
        "The app restarted while this was in flight to \(name). It may have reached \(name); if \(name) answers, the answer arrives in this "
            + "conversation. Nothing was resent; send it again only if no answer comes and you still want it."
    }
    /// A sending row still holds its previous receipt and needs a fresh interruption receipt. Preserve other sends’ locators: remote work may finish after
    /// the local wait ends.
    static func interrupted(_ row: inout AgentConversationRecord) {
        guard row.phase != "sending", case .object(var root)? = row.receipt else {
            var fields: [String: JSONValue] = ["status": .string("interrupted"), "completed": .bool(false),
                "detail": .string(restartDetail(row.name))]
            if let conversation = row.conversationID { fields["conversation_id"] = .string(conversation) }
            absorb(.object(fields), into: &row)
            return
        }
        let detail = row.phase == "attention"
            ? """
                An app restart ended this app's wait for \(row.name)'s reply. Nothing was resent; if the reply comes, it still arrives here when \
                this conversation is read, so send again only if it is still wanted.
                """
            : restartDetail(row.name)
        func settle(_ fields: inout [String: JSONValue]) {
            fields["status"] = .string("interrupted")
            if fields["run_status"] != nil { fields["run_status"] = .string("interrupted") }
            fields["completed"] = .bool(false)
            fields["detail"] = .string(detail)
        }
        settle(&root)
        absorb(.object(root), into: &row)
    }
    /// Unknown dispatched outcomes fence the thread while their call is live; executable approvals fence it until terminal evidence or explicit
    /// cancellation. This projection cannot replace the checked approval owner used by executable waits.
    package static func unsettledAttention(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "attention", !stoppedOrReleased(row), case .object(let root)? = row.receipt else { return false }
        let value = row.sendEvidence
        if root["sent"] == .bool(false) || value["sent"] == .bool(false) { return false }
        let status = string(value["run_status"]) ?? string(value["status"]) ?? ""
        // Unknown outcomes hold the thread only while their owning call can still produce a reply: a call that ended produces none.
        return ["outcome_unknown", "delivery_unknown"].contains(status) && value["terminal"] != .bool(true)
                && AgentConversationRunning.shared.live(row: row.id, operation: row.operationID)
            || AgentConversationRecord.approvalWaits(status)
    }
    /// Retain an approved exchange’s place ahead of its queue until replay claims it; terminal approval evidence releases it.
    static func unsettledAttentionChecked(_ row: AgentConversationRecord, dataRoot: URL) throws -> Bool {
        guard unsettledAttention(row) else { return false }
        let value = row.sendEvidence
        let status = string(value["run_status"]) ?? string(value["status"]) ?? ""
        if AgentConversationRecord.approvalWaits(status), case .object(let root)? = row.receipt {
            let operation = "agent.approval-wait:" + row.operationID
            let approval = string(value["approvalId"]) ?? string(root["approvalId"])
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
        return AgentConversationRecord.approvalWaits(string(value["run_status"]) ?? string(value["status"]) ?? "")
    }
    /// Cancellation settles the local wait; a retired desktop reader leaves late remote answers in their chat.
    package static func stoppedOrReleased(_ row: AgentConversationRecord) -> Bool {
        guard let stop = row.stop, stop.operationID == row.operationID else { return false }
        return ["stopped", "released"].contains(stop.state)
    }
}
