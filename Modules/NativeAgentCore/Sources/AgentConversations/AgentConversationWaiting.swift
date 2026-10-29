import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import TurnTrace

// Blueprint: | `AgentConversationWaiting.swift` | Conversation waits, interrupted recovery and approval readiness |
extension AgentConversationSession {
    /// `wait` on a contact: back as soon as the reply in flight on its thread
    /// settles (every settle is a store write, which wakes this) or when
    /// `seconds` run out, saying which. What it returns is `read`'s agent_read.
    /// `admit` (agent_read's own wait) reads through the gates first, so a
    /// read that would be refused is refused, not waited past.
    package static func waitForReply(input: [String: JSONValue], scope: String, dataRoot: URL, admit: Bool = false,
                             read: @escaping Dispatch) async throws -> JSONValue {
        guard var agent = string(input["agent"]) else { throw AgentConversationStore.Failure(message: "Name the contact to wait for.") }
        agent = AgentConversationDelivery.door(for: agent, dataRoot: dataRoot)?.agent ?? agent
        let store = AgentConversationStore(dataRoot: dataRoot)
        let records = Result { try store.records() }
        let pinned = named(string(input["conversation"]), agent: agent, scope: scope, rows: (try? records.get()) ?? [])
        let label = pinned.label
        let exact = input.filter { ["conversation_id", "message_id", "task_id"].contains($0.key) && $0.value != .null && $0.value != .string("") }
        let retained = exact.isEmpty ? nil : try records.get().filter { row in
            row.agent == agent && exact.allSatisfy { key, value in
                key == "conversation_id" ? row.conversationID.map(JSONValue.string) == value : row.readInput?[key] == value
            }
        }.max { $0.updatedAt < $1.updatedAt }
        var readInput = exact
        readInput["agent"] = .string(agent)
        // The name she gave, so the read resolves to this same record.
        if let label { readInput["conversation"] = input["conversation"] ?? .string(label) }
        for key in ["session_id", "__session_id", "details"] { readInput[key] = input[key] }
        if !exact.isEmpty, retained == nil {
            var result = try await read("agent_read", readInput)
            if case .object(var fields) = result { fields["wait_outcome"] = .string("not_tracked"); result = .object(fields) }
            return result
        }
        let asked: Double = switch input["seconds"] { case .int(let n)?: Double(n); case .double(let n)?: n; default: 60 }
        let started = Date()
        let deadline = started.addingTimeInterval(min(max(asked, 1), 300))
        if let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { "peer:" + $0.id == agent }),
           peer.ability == nil, ChatGPTDotIPCTransport.owns(peer) {
            // His reply lands through the listener, which marks the change.
            var seen = AgentConversationRunning.shared.seen
            var snapshot = try await read("agent_read", readInput)
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
                snapshot = try await read("agent_read", readInput)
                if readRefused(snapshot) { return snapshot }
                outcome = "settled"
            }
            guard case .object(var fields) = snapshot else { return snapshot }
            fields["wait_outcome"] = .string(outcome)
            fields["waited_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
            return .object(fields)
        }
        if admit {
            let first = try await $returnsHistory.withValue(false) { try await read("agent_read", readInput) }
            if readRefused(first) { return first }
        }
        let transport = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == agent }?.transport
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
            guard replyInFlight(row, transport) else {
                if outcome != "nothing_in_flight" { outcome = "settled" }
                break
            }
            outcome = "still_waiting"
            if Date() >= deadline { break }
            await AgentConversationRunning.shared.change(after: seen, until: deadline)
        }
        if Task.isCancelled { outcome = "cancelled" }
        // Out of time (or stopped): the saved snapshot, never another read
        // that could hold the turn past `seconds`.
        let snapshot: JSONValue?
        if ["still_waiting", "cancelled"].contains(outcome), let latest {
            snapshot = AgentConversationView.view(latest, details: input["details"] == .bool(true), dataRoot: dataRoot, includeHistory: false)
        } else {
            snapshot = try await $returnsHistory.withValue(false) { try await read("agent_read", readInput) }
        }
        guard case .object(var fields)? = snapshot else { return .object(["wait_outcome": .string(outcome)]) }
        // Grok Bot's answer is in this turn's hands now: it is not handed over again.
        // Only a wait that read it back (settled, or already there) and carries
        // that exact answer claims it; a stopped or timed-out wait never does.
        if transport == .grokBot, ["settled", "nothing_in_flight"].contains(outcome), !Task.isCancelled,
           let delivered = string(fields["reply"]), let latest, agent.hasPrefix("peer:"),
           let message = string(latest.readInput?["message_id"]) {
            let clipped = fields["reply_truncated"] == .bool(true)
            GrokRequestStore(dataRoot: dataRoot).shown(message, peer: String(agent.dropFirst(5)), by: "wait") {
                $0 == delivered || (clipped && $0.hasPrefix(delivered))
            }
        }
        // A contact's wait hands back the exchange, not its retained history.
        if agent.hasPrefix("peer:"), let latest,
           case .object(let shown) = AgentConversationView.compact(.object(fields), row: (try? store.records().first { $0.id == latest.id }) ?? latest) {
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
    /// The thread is occupied: its reply is still coming, or a queued message
    /// is ahead (waiting or taken to go next). A new message queues behind.
    static func inFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?) -> Bool {
        replyInFlight(row, transport) || AgentConversationRunning.shared.watched(row.id) || row.queueReservation != nil
            || row.queued?.contains(where: { $0.held == nil }) == true
    }
    /// The reply ahead is still coming. A "sending" row only counts while this
    /// process still owns that send.
    static func replyInFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?) -> Bool {
        if row.phase == "sending" { return AgentConversationRunning.shared.live(row: row.id, operation: row.operationID) }
        // A live hand-off settles on its own reply, delivery of an FYI, or release.
        if liveHandOff(row), row.phase == "waiting" || stoppedOrReleased(row) { return !settled(row) }
        if unsettledAttention(row) { return true }
        guard row.phase == "waiting" else { return false }
        // A desktop answer, or a background send, is watched by this process; none after a restart.
        if transport == .desktop || backgroundSend(row) { return !stoppedOrReleased(row) && AgentConversationRunning.shared.routeWatching(row: row.id, operation: row.operationID) }
        // Every other lane settles on its own receipt, or a stop.
        return !stoppedOrReleased(row)
    }
    /// A send still running in this process's background task (ACP, command
    /// line, NativeAgent peer): waiting only while that task watches it.
    static func backgroundSend(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "waiting", case .object(let receipt)? = row.receipt else { return false }
        return receipt["background_send"] == .bool(true)
    }
    /// At launch, before queued follow-ups resume: a send no process owns any
    /// more settles as interrupted and unanswered, never waiting forever. That
    /// is a background send, any lane's send caught mid-way, or one left with
    /// an unknown outcome, begun before this process. Nothing is resent.
    static func settleInterrupted(dataRoot: URL) {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let running = AgentConversationRunning.shared
        let desktop = Set(((try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []).filter { $0.transport == .desktop }.map { "peer:" + $0.id })
        func orphaned(_ row: AgentConversationRecord) -> Bool {
            if backgroundSend(row) { return !running.routeWatching(row: row.id, operation: row.operationID) }
            guard ownerless(row) else { return false }
            // Only a desktop answer is watched by the process that pasted it; every
            // other waiting lane settles on its own evidence after a restart.
            if row.phase == "waiting" { return desktop.contains(row.agent) && !running.routeWatching(row: row.id, operation: row.operationID) }
            return row.phase == "sending" || unsettledAttention(row) && !awaitingApproval(row)
        }
        // A receipt correction, not news: an old row keeps its time (a phase change still moves it).
        for row in (try? store.records()) ?? [] where orphaned(row) {
            _ = try? store.update(id: row.id, operationID: row.operationID, touch: false) {
                guard orphaned($0) else { return }
                interrupted(&$0)
            }
        }
        // The restart that cut a reply off may also have marked the agent
        // unavailable, which hides it from the sidebar with no way back. Where
        // an agent's newest send is that interrupted one, lift a mark written
        // since it began (a later real failure would be its own, newer send).
        let peers = AgentPeerStore(dataRoot: dataRoot)
        // Rank sends by their start, preserving updatedAt ordering for legacy records.
        let newest = Dictionary(((try? store.records()) ?? []).filter { $0.agent.hasPrefix("peer:") }
            .map { row in (row.agent, (row: row, startedAt: row.operationStartedAt ?? row.updatedAt)) }) {
                a, b in a.startedAt >= b.startedAt ? a : b
            }
        for (agent, send) in newest {
            guard case .object(let receipt)? = send.row.receipt, receipt["status"] == .string("interrupted") else { continue }
            peers.clearUnavailable(peerID: String(agent.dropFirst(5)), since: send.startedAt)
        }
    }
    /// Begun before this process and not running in it: no process owns this
    /// send any more. Never judged by liveness alone (a send of this process
    /// is briefly not yet registered as live).
    static func ownerless(_ row: AgentConversationRecord) -> Bool {
        (row.operationStartedAt ?? row.updatedAt) < AbandonedTurnReconciler.processEpoch
            && !AgentConversationRunning.shared.live(row: row.id, operation: row.operationID)
    }
    /// What a send the app's own quit or restart cut off says: its turn ended
    /// with the process, so it was not answered here and nothing is resent.
    package static func restartDetail(_ name: String) -> String {
        "Interrupted by an app restart before \(name)'s reply came back, so it was not answered here. Nothing was resent; send it again if it is still wanted."
    }
    /// Settles the row's send as one the restart cut off. A send still
    /// "sending" holds the previous exchange's receipt, so it gets a fresh one;
    /// any other keeps its ids and read locator. An unknown outcome may still
    /// finish remotely: only the wait is let go, so a reply that comes can be read back.
    static func interrupted(_ row: inout AgentConversationRecord) {
        guard row.phase != "sending", case .object(var root)? = row.receipt else {
            var fields: [String: JSONValue] = ["status": .string("interrupted"), "completed": .bool(false),
                "detail": .string(restartDetail(row.name))]
            if let conversation = row.conversationID { fields["conversation_id"] = .string(conversation) }
            absorb(.object(fields), into: &row)
            return
        }
        let detail = row.phase == "attention"
            ? "An app restart ended this app's wait for \(row.name)'s reply. Nothing was resent; if the reply comes, it still arrives here when this conversation is read, so send again only if it is still wanted."
            : restartDetail(row.name)
        func settle(_ fields: inout [String: JSONValue]) {
            fields["status"] = .string("interrupted")
            if fields["run_status"] != nil { fields["run_status"] = .string("interrupted") }
            fields["completed"] = .bool(false)
            fields["detail"] = .string(detail)
        }
        settle(&root)
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(var job) = jobs[0] {
            settle(&job)
            root["jobs"] = .array([.object(job)])
        }
        absorb(.object(root), into: &row)
    }
    /// An attention send that may still act: dispatched with an unknown outcome
    /// (it may be running remotely), or held on an approval that may still send
    /// it. It fences the thread until terminal evidence or agent_cancel.
    package static func unsettledAttention(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "attention", !stoppedOrReleased(row), case .object(let root)? = row.receipt else { return false }
        let value = row.sendEvidence
        if root["sent"] == .bool(false) || value["sent"] == .bool(false) { return false }
        let status = GrokBotRoute.normalizedStatus(string(value["run_status"]) ?? string(value["status"]) ?? "")
        if AgentConversationRecord.approvalWaits(status), approvalDecided(string(value["approvalId"]) ?? string(root["approvalId"])) {
            return false
        }
        // An unknown outcome holds the thread while its reply may still come;
        // a terminal one (its call ended, bounded by the route's own timeout)
        // has nothing more coming, so the next message goes.
        return ["outcome_unknown", "delivery_unknown"].contains(status) && value["terminal"] != .bool(true)
            || AgentConversationRecord.approvalWaits(status)
    }
    /// A send held on an approval stops fencing the thread once that approval is
    /// decided (denied, expired), or its approved replay has finished. Keep the
    /// approved exchange's place until its replay claims it, ahead of its queue.
    static func approvalDecided(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        let url = PersistenceCore.defaultDataRoot().appendingPathComponent("workflows/approvals/requests.json")
        guard let rows = try? SwiftNativeApprovalInbox.loadApprovalRowsChecked(at: url),
              let value = rows.first(where: { if case .object(let row) = $0 { row["id"] == .string(id) } else { false } }),
              case .object(let row) = value, row["status"] != .string("pending") else { return false }
        if row["decision"] == .string("approved") { return row["executedAction"] != nil && row["executedAction"] != .null }
        return true
    }
    /// Held on an approval the person has not decided yet: lifecycle events
    /// wake the queue when the decision or replay receipt lands in its store.
    static func awaitingApproval(_ row: AgentConversationRecord) -> Bool {
        guard unsettledAttention(row) else { return false }
        let value = row.sendEvidence
        return AgentConversationRecord.approvalWaits(string(value["run_status"]) ?? string(value["status"]) ?? "")
    }
    /// agent_cancel settled this send: the lane stopped it, or (where there is
    /// no stop) the thread let go of waiting; a retired desktop reader leaves
    /// any late answer in the remote chat.
    package static func stoppedOrReleased(_ row: AgentConversationRecord) -> Bool {
        guard let stop = row.stop, stop.operationID == row.operationID else { return false }
        return ["stopped", "released"].contains(stop.state)
    }
}
