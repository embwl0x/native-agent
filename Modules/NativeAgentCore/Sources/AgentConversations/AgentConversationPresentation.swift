import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import TurnTrace

// Blueprint: | `AgentConversationPresentation.swift` | Canonical receipt interpretation and retained-history reads through AgentConversationView |
extension AgentConversationSession {
    /// A routine (Grok Bot) answers as its own turn in the chat that asked,
    /// never in the send record. Its read carries both sides in time order:
    /// her asks from the record (any chat), its replies from those chats
    /// (HerScreen.routineReplies, matched by the request's run id).
    static func routineRead(agent: String, name: String, peer: AgentPeerContact?, row: AgentConversationRecord?,
                                    store: AgentConversationStore, args: [String: JSONValue], dataRoot: URL,
                                    perform: Dispatch) async throws -> JSONValue {
        var result: JSONValue = .object(["agent": .string(name), "agent_id": .string(agent), "status": .string("no_history"), "state": .string("no_history")])
        // Refresh only when the send retained the request id required by the route.
        if let row { result = AgentConversationView.view(row.readInput == nil ? row : try await refresh(row, store: store, input: args, perform: perform), details: false, read: true, dataRoot: dataRoot, includeHistory: returnsHistory) }
        // Merge contact history with handed-over turns from the chats that asked.
        // Identical reply text within ten minutes is shown once.
        let said = try ContactThread.mergedLines(dataRoot: dataRoot, owner: agent.hasPrefix("peer:") ? String(agent.dropFirst(5)) : agent, identity: AgentContactIdentity(dataRoot: dataRoot))
        let turns = await HerScreen.routineReplies(dataRoot: dataRoot).filter { turn in
            !said.contains { !$0.mine && $0.text == turn.text && abs($0.at.timeIntervalSince(turn.date ?? $0.at)) < 600 }
        }
        let talk = ContactThread.project((said + turns).sorted { $0.at < $1.at }.suffix(8), names: [agent: name], unattested: name,
            mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) })
        guard case .object(var fields) = result, !talk.isEmpty else { return result }
        if talk.contains(where: { !$0.mine }) {
            // The current ask's own state comes from its request id (refreshed
            // above). A late answer to a superseded ask shows here but never
            // reads as the answer to the one still waiting.
            if fields["last_send_reply_state"] != .string("no_reply_expired"), !["waiting", "sending"].contains(fields["state"].flatMap { if case .string(let v) = $0 { v } else { nil } } ?? "") {
                fields["state"] = .string("replied")
            }
            fields["untrusted_remote_data"] = .bool(true)
        }
        fields["conversation"] = .array(talk.map { shown in
            .object(["at": shown.date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null, "from": .string(shown.speaker),
                     "text": .string(HerScreen.clip(shown.text, 800))])
        })
        fields["conversation_note"] = .string("Oldest first: the messages sent and its replies, each reply after the message it answers.")
        return .object(fields)
    }
    static func refresh(_ row: AgentConversationRecord, store: AgentConversationStore,
                                input: [String: JSONValue], perform: Dispatch) async throws -> AgentConversationRecord {
        var read = row.readInput ?? ["agent": .string(row.agent)]
        read["details"] = .bool(true)
        for key in ["session_id", "__session_id"] { read[key] = input[key] }
        let receipt = try await perform("agent_read", read)
        // Synchronous command/ACP adapters do not expose a recovery endpoint.
        // Their gate still ran; show the clearly labelled retained last result.
        // A read that did not reach its owner cannot expose a cached reply.
        if readRefused(receipt) {
            throw readFailure(receipt, agent: row.agent)
        }
        // A contact with nothing to read on its side (a desktop or inbound-only
        // door: "read": false) still has the conversation as it stands here.
        if case .object(let value) = receipt, value["status"] == .string("nothing_to_read") || value["read"] == .bool(false) {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        if row.readInput == nil {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        // A look is not news: the time moves only when the reply or state does.
        do {
            let receipt = try await store.retainReply(receipt, for: row)
            let refreshed = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                var observed = $0
                absorb(receipt, into: &observed)
                // A settled failure changes only for a genuine late answer or an observed failure.
                let settledFailure = $0.phase != "sending" && $0.sendFailed
                let lateAnswer = observed.exchanges?.last(where: { $0.id == row.operationID })?.reply != nil
                if !settledFailure || lateAnswer || observed.sendFailed { $0 = observed }
                $0.selected = true
            }
            return refreshed
        } catch {
            // If a queued send advanced the operation during this read, return the current thread.
            if let now = try? store.records().first(where: { $0.id == row.id }), now.operationID != row.operationID { return now }
            throw error
        }
    }
    static func record(_ receipt: JSONValue, for row: AgentConversationRecord,
                               store: AgentConversationStore, peer: AgentPeerContact?,
                               firstActivity: Date? = nil, inline: Bool = false, background: Bool = false,
                               queued: Bool = false, stopped: Bool = false) throws -> AgentConversationRecord {
        try store.update(id: row.id, operationID: row.operationID) {
            // Preserve an already-settled answer; a background send settles only its own running exchange.
            guard $0.phase == "sending" || background && backgroundSend($0) else { return }
            // Don't keep a previous request locator for a new uncertain send.
            $0.readInput = nil
            absorb(receipt, into: &$0)
            if stopped, !AgentConversationRunning.shared.observing(row: row.id, operation: row.operationID) {
                let detail = if case .object(let fields) = receipt { string(fields["detail"]) } else { nil as String? }
                $0.stop = AgentConversationStop(state: "released", operationID: row.operationID, at: Date(), detail: detail ?? "Local work stopped; the remote outcome is unknown. Nothing was resent.")
                $0.phase = "ready"
            }
            $0.automaticRead = $0.phase == "waiting" && $0.readInput != nil
                && (peer?.transport == .a2a || peer?.transport == .nativeAgent)
            $0.nextReadAt = $0.automaticRead ? Date() : nil
            if !isRefusal(receipt) { $0.selected = true }
            if let firstActivity, let index = $0.exchanges?.lastIndex(where: { $0.id == row.operationID }) {
                $0.exchanges?[index].firstActivityAt = firstActivity
            }
            $0.shownInline = inline && $0.phase != "waiting" && !heldReplyPending($0) ? $0.operationID + ":" + $0.phase : nil
            // Publish settlement and delivery together, before a queued sender
            // can observe the finished exchange and advance this conversation.
            if background, $0.personInitiated != true, $0.phase != "waiting", !heldReplyPending($0), !$0.automaticRead,
               !stoppedOrReleased($0), !AgentConversationRunning.shared.watched($0.id) {
                $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
            }
            // A queued follow-up went while nobody was waiting on this call: a
            // contact's answer (or its refusal) then comes to her as a turn, as a
            // delayed reply does. A send-only route has nothing to hand over.
            if queued, $0.personInitiated != true, peer != nil, !$0.automaticRead, $0.phase != "waiting",
               case .object(let fields)? = $0.receipt, AgentConversationView.reply(fields) != nil || fields["sent"] == .bool(false) {
                $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
            }
        }
    }
    /// Her own conversation with the agent: the one chat session the contact
    /// owns (`ContactThread.session`), whichever chat she reached it from.
    /// None for a helper bot, whose conversation is its shelf.
    static func threadID(_ agent: String) -> String? {
        if agent.hasPrefix("peer:") { return ContactThread.session(owner: String(agent.dropFirst(5))) }
        return nil
    }
    /// Names the thread a send implicitly went on in, and how old it was.
    static func noting(_ result: JSONValue, carried: AgentConversationRecord?) -> JSONValue {
        guard let carried, let last = carried.exchanges?.last, case .object(var fields) = result else { return result }
        let when = last.settledAt ?? last.sentAt
        guard let seconds = Int(exactly: max(0, Date().timeIntervalSince(when)).rounded(.towardZero)) else {
            fields["thread_note"] = .string("The saved conversation date is invalid; preserve and repair its history before continuing.")
            return .object(fields)
        }
        let ago = seconds < 5400 ? "\(max(1, seconds / 60)) minutes" : seconds < 172_800 ? "\(seconds / 3600) hours" : "\(seconds / 86400) days"
        fields["thread_note"] = .string("No conversation was named, so this went on in “\(carried.label)”, begun in another chat; its last message was \(ago) earlier (\(ISO8601DateFormatter().string(from: when))). Name a conversation, or pass new_conversation: true, to keep a new topic apart.")
        return .object(fields)
    }
    /// Resolve a conversation by label or id; exact record and conversation ids take precedence.
    /// Return its label and record, or the supplied label without a record when unmatched.
    static func named(_ label: String?, agent: String, scope: String, rows: [AgentConversationRecord]) -> (label: String?, record: AgentConversationRecord?) {
        guard let label else { return (nil, nil) }
        let rows = rows.filter { $0.agent == agent }
        let exact = rows.first { $0.id == label } ?? rows.filter { $0.conversationID == label }
            .max { ($0.scopeSessionID == scope ? 1 : 0, $0.updatedAt) < ($1.scopeSessionID == scope ? 1 : 0, $1.updatedAt) }
        return exact.map { ($0.label, $0) } ?? (label, nil)
    }
    static func readFailure(_ receipt: JSONValue, agent: String) -> ToolFailureError {
        let fields: [String: JSONValue] = if case .object(let value) = receipt { value } else { [:] }
        let remedy: [String: JSONValue] = if case .object(let value)? = fields["remedy"] { value } else { [:] }
        let call = remedy["next_call"].flatMap { $0.objectValue }.flatMap { try? JSONValue.object($0).serialize(pretty: false) }
        let kind = string(remedy["kind"])
        let status = string(fields["status"])
        return ToolFailureError(string(fields["detail"]) ?? string(fields["error"]) ?? "The agent read returned no conversation receipt.",
            effects: .none, owner: string(remedy["owner"]) ?? agent,
            nextCall: call ?? (kind == "terminal" || remedy["tap"] != nil ? nil : ToolFailureError.call("app", ["action": .string("agent.contacts")])),
            tap: string(remedy["tap"]), personDecides: kind == "person_decides",
            code: string(fields["failure_code"]) ?? string(fields["reason"]) ?? status ?? "agent_conversation_read_unavailable",
            status: status.flatMap(ToolFailureError.Status.init(rawValue:)) ?? (["blocked", "denied", "blocked_by_trust"].contains(status ?? "") || AgentConversationRecord.approvalWaits(status ?? "") ? .refused : .failed),
            instruction: string(remedy["instruction"]) ?? "Read contacts for this agent's access requirement before opening the conversation.",
            recovery: kind.flatMap(ToolFailureError.Recovery.init(rawValue:)) ?? (call == nil ? .inspect : .repair))
    }
    package static func absorb(_ receipt: JSONValue, into row: inout AgentConversationRecord) {
        var receipt = AgentConversationView.expiringReply(receipt)
        if row.phase != "sending", case .object(let previous)? = row.receipt,
           let path = previous["filePath"], case .object(var fields) = receipt, fields["filePath"] == nil {
            fields["filePath"] = path
            receipt = .object(fields)
        }
        // A wake owns completion. A lookup before its job is visible, or
        // while its receipt is unreadable, is not a terminal no-reply result.
        if row.readInput != nil, row.phase == "waiting",
           case .object(let root) = receipt,
           (root["jobs"] == .array([]) || ["not_found", "unavailable", "unknown"].contains(string(root["status"]) ?? "")),
           root["terminal"] != .bool(true), root["sent"] != .bool(false) {
            return
        }
        row.receipt = AgentConversationStore.cacheReceipt(receipt)
        guard case .object(let root) = receipt else { row.phase = "attention"; return }
        let value = row.sendEvidence
        if let conversation = string(value["conversation_id"]) ?? string(value["conversationId"]) { row.conversationID = conversation }
        else if let thread = string(value["thread_id"]) { row.conversationID = "codex:" + thread }
        // A route with no saved chat says null; the next send opens one.
        else if value["conversation_id"] == .null { row.conversationID = nil }
        if case .object(let action)? = root["read_with"], case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        } else if let locator = AgentConversationRouting.readLocator(agent: row.agent,
            message: value["message_id"] ?? value["messageId"] ?? value["matched_message_id"],
            conversation: row.conversationID.map(JSONValue.string), task: value["task_id"]),
                  case .object(let action) = locator, case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        }
        let state = GrokBotRoute.normalizedStatus(row.sendStatus)
        // A contact that pulls (an MCP host with no command line) took nothing
        // yet: the message is held and the thread is free (`takeHeld` drains it).
        if state == "held" {
            row.phase = "ready"
        } else if isRefusal(receipt) || AgentConversationRecord.approvalWaits(state) || ["failed", "interrupted", "waiting_on_you", "waiting_on_person", "waiting on you", "outcome_unknown", "unavailable", "cancelled", "canceled", "stopped", "reconnect_required", "session_unavailable"].contains(state) {
            row.phase = "attention"
        } else if row.agent.hasPrefix("peer:"), ["answered", "replied"].contains(state), value["reply"] == nil, value["answer"] == nil {
            // "Answered" without a reply field is a status, never an answer.
            row.phase = "attention"
        } else if AgentConversationDelivery.claudeInbox(row), ["delivered", "delivered_live", "queued", "read"].contains(state), AgentConversationView.reply(value) == nil {
            row.phase = (root["read"] ?? value["read"]) == .bool(true) && !row.awaitsReply ? "ready" : "waiting"
        } else if (value["needs_input"] == .bool(true) || value["completed"] == .bool(true)
                    || value["terminal"] == .bool(true) || ["replied", "completed", "succeeded", "done", "answered"].contains(state)) && AgentConversationDelivery.accepted(row)
                    || (state == "delivered_live" && AgentConversationView.reply(value) != nil) {
            // A live hand-off whose answer came back (a bridge reply naming it) is answered.
            row.phase = "ready"
        } else if ["enqueued", "queued", "running", "working", "submitted", "accepted", "delivering", "pending", "delivered", "sent", "delivered_live", "delivery_unknown"].contains(state) {
            // delivered_live: in the agent's live session; its answer is a chat of its own (`settled`).
            row.phase = "waiting"
        } else if AgentConversationView.reply(value) != nil {
            row.phase = "ready"
        } else { row.phase = "attention" }
        if row.phase != "waiting" { row.nextReadAt = nil; row.automaticRead = false }
    }
    /// Handed straight into the agent's live session.
    package static func liveHandOff(_ row: AgentConversationRecord) -> Bool {
        let value = row.sendEvidence
        return (value["run_status"] ?? value["status"]) == .string("delivered_live")
    }
    /// Only this exchange's settlement can release an owed reply.
    static func settled(_ row: AgentConversationRecord) -> Bool {
        stoppedOrReleased(row) || row.phase == "ready"
            || (!row.awaitsReply && [.delivered, .read].contains(AgentConversationDelivery.of(row, read: false)))
    }
    static func confirmedNotSent(_ row: AgentConversationRecord) -> Bool {
        guard case .object(let receipt)? = row.receipt,
              receipt["sent"] == .bool(false) else { return false }
        // Only a new explicit message may try again after a pre-dispatch refusal.
        // Pending approvals and uncertain/accepted sends still require recovery;
        // the adapter rechecks current authority and connection on every attempt.
        return ["reconnect_required", "unavailable", "needs_setup", "no_outbound_route",
                "blocked", "denied", "blocked_by_trust", "busy", "invalid_arguments"].contains(string(receipt["status"]) ?? "")
    }
    /// A send that did not reach its owner: refused, or `sent: false`.
    static func isRefusal(_ receipt: JSONValue) -> Bool {
        guard case .object(let row) = receipt else { return true }
        return readRefused(receipt) || row["sent"] == .bool(false)
            || ["needs_setup", "no_outbound_route"].contains(string(row["status"]) ?? "")
    }
    /// Read refusals require errors or explicit gates; `sent: false` and missing outbound routes permit reads.
    package static func readRefused(_ receipt: JSONValue) -> Bool {
        guard case .object(let row) = receipt else { return true }
        if ["needs_setup", "no_outbound_route"].contains(string(row["status"]) ?? "") { return false }
        return (row["terminal"] != .bool(true) && ChatToolOutcome.carriesFailureEvidence(.object(row.filter { $0.key != "result" }))) || AgentConversationRecord.approvalWaits(string(row["status"]) ?? "")
    }
    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }; return value
    }
    static func unknownContact(_ agent: String, contacts: [(String, String)]) -> JSONValue {
        let requested = Array(agent.lowercased())
        struct Candidate { let id: String; let name: String; let distance: Int }
        var ranked: [Candidate] = contacts.map { Candidate(id: $0.0, name: $0.1, distance: characterEditDistance(requested, Array($0.1.lowercased()))) }
        ranked.sort { (a: Candidate, b: Candidate) -> Bool in
            a.distance == b.distance ? a.name < b.name : a.distance < b.distance
        }
        let nearest: [JSONValue] = ranked.prefix(3).map { (candidate: Candidate) -> JSONValue in
            .object(["agent": .string(candidate.id), "name": .string(candidate.name)])
        }
        return .object(["status": .string("unknown_contact"), "state": .string("unknown_contact"),
            "agent": .string(agent), "nearest_contacts": .array(nearest), "effects": .string("none"),
            "execution": .string("not_run"), "effect": .string("none"),
            "detail": .string("No contact has that name. Choose one of the nearest contacts or read agent.contacts.")])
    }
    static func agentIsBot(_ input: [String: JSONValue]) -> Bool {
        string(input["agent"])?.hasPrefix("bot:") == true
    }
    static func attention(_ name: String, label: String, _ text: String) -> JSONValue {
        .object(["agent": .string(name), "conversation": .string(label), "state": .string("attention"), "detail": .string(text), "sent": .bool(false)])
    }
}
