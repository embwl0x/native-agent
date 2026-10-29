import AgentWorkspace
import NativeAgentShared
import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnContracts
import Experiences
import TurnTrace
// Blueprint: | `AgentConversationReplies.swift` | Locked retained-answer delivery, inline waits and reply settlement on the existing conversation store |

extension AgentConversationStore {
    /// A contact's answer that settled in this write goes into the contact's own session, unless her turn carries it there (being handed over, or handed over by a turn already). There it is an arrival for her too (ResidentWake), unless it
    /// came as a turn or is the person's own send. `from`/`steeredBy`: the stamp of who said the reply, as its transport attested it.
    func noteReplies(was before: AgentConversationRecord, now row: AgentConversationRecord, wake: Bool = true,
                             from: String, steeredBy: [String] = [], answer: (id: String, text: String)? = nil,
                             retained: String? = nil) {
        guard row.agent.hasPrefix("peer:") else { return }
        let receipt: [String: JSONValue] = if case .object(let fields)? = row.receipt { fields } else { [:] }
        guard receipt["retention_error"] == nil else { return }
        let earlier = Dictionary((before.exchanges ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        for exchange in row.exchanges ?? [] {
            guard let reply = exchange.reply, let at = exchange.settledAt,
                  earlier[exchange.id].map({ $0.reply == nil || $0.settledAt == nil }) ?? true,
                  exchange.id != row.operationID || (row.deliveryState != "delivering" && row.deliveryRunID == nil) else { continue }
            if exchange.id != retained, exchange.id != row.operationID || receipt["reply_location"] == nil {
                let original = exchange.id == row.operationID ? AgentConversationExchange.answer(receipt) : (text: nil, truncated: false)
                let source = answer?.id == exchange.id ? (answer!.text, false)
                    : (original.text ?? reply, original.text == nil ? exchange.replyTruncated : original.truncated)
                // An upstream excerpt remains labelled in the receipt/ledger; it cannot become a complete message in the contact's thread.
                if !source.1 {
                    let entry = ContactThread.Entry.reply(owner: String(row.agent.dropFirst(5)), name: row.name,
                        text: source.0, replyID: "agent-conversation:" + exchange.id, at: at, from: from, steeredBy: steeredBy)
                    // Its own task, carrying none of the writer's turn with it.
                    Task.detached { await ContactThread.write(entry, dataRoot: root) }
                }
            }
            guard wake, row.personInitiated != true, row.shownInline != row.operationID + ":" + row.phase,
                  !(exchange.id == row.operationID && AgentConversationRunning.shared.watched(row.id)) else { continue }
            ResidentWake.shared.request(dataRoot: root, reason: "what resolved", items: [.init(
                id: "reply:" + exchange.id, line: row.name + " replied in \"" + String(row.label.prefix(60)) + "\"", thread: row.id,
                session: row.scopeSessionID)])
        }
    }

    /// A collected remote answer belongs to an inline waiter before it can become a separate turn. Serialized with the waiter's deadline release.
    package func offerReplyToInlineWait(_ row: AgentConversationRecord, receipt: JSONValue) throws -> Bool {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == row.id && $0.operationID == row.operationID }) else { return false }
            if rows[i].shownInline == row.operationID + ":ready" { return true }
            guard AgentConversationRunning.shared.watched(row.id) else { return false }
            let before = rows[i]
            AgentConversationSession.absorb(receipt, into: &rows[i])
            guard rows[i].phase != "waiting" else { return false }
            rows[i].automaticRead = false; rows[i].nextReadAt = nil; rows[i].deliveryState = nil
            rows[i].updatedAt = Date()
            try Self.absorbExchange(into: &rows[i], file: fileURL)
            try save(rows)
            noteReplies(was: before, now: rows[i], wake: false, from: rows[i].agent)
            return true
        }
    }

    /// The bridge's actual inbound message, before starting another turn. An explicit reply names its send; a pull host answers the sole delivered held send in the conversation it was given. The call that first drains that send cannot
    /// answer it: its exchange is still `delivering`. Claim and deadline release share this lock; only the winner delivers. The bridge records its receipt before save publishes the answer to the waiter. An already claimed answer does not
    /// write that receipt again.
    public func offerBridgeReplyToInlineWait(agent: String, messageID: String? = nil,
                                             conversationID: String? = nil, text: String,
                                             from: String, steeredBy: [String],
                                             recordReply: () throws -> Void = {}) throws -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let identity = AgentContactIdentity(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        return try locked {
            var rows = try load()
            let matches = rows.indices.filter { index in
                let row = rows[index]
                guard identity.canonical(row.agent) == identity.canonical(agent) else { return false }
                if let messageID { return row.readInput?["message_id"] == .string(messageID) }
                return conversationID != nil && row.conversationID == conversationID
                    && AgentConversationSession.heldReplyPending(row)
                    && row.exchanges?.last(where: { $0.id == row.operationID })?.status == "delivered"
            }
            guard matches.count == 1, let index = matches.first else { return false }
            let before = rows[index]
            let receipt: [String: JSONValue] = if case .object(let fields)? = before.receipt { fields } else { [:] }
            if before.shownInline == before.operationID + ":ready",
               AgentConversationExchange.answer(receipt).text == text {
                try recordReply()
                return true
            }
            guard AgentConversationRunning.shared.watched(before.id),
                  before.phase == "waiting" || AgentConversationSession.heldReplyPending(before) else { return false }
            try answer(&rows[index], text: text, from: from, steeredBy: steeredBy)
            rows[index].shownInline = before.operationID + ":ready"
            rows[index].deliveryState = nil
            try recordReply()
            try save(rows)
            noteReplies(was: before, now: rows[index], wake: false, from: from,
                        steeredBy: steeredBy, answer: (before.operationID, text))
            return true
        }
    }

    /// One message of hers held for a contact that pulls (an MCP host with no command line): it goes out in the result of that host's next call.
    public struct Held: Sendable {
        public let row: String
        public let exchange: String
        public let at: Date
        public let text: String
        public let conversation: String?
    }

    /// THE DRAIN, one serialized step: the held messages for `agent`, oldest first, as many as `fits` allows, each marked delivering in the same write, so no other call sees what this one took. `remaining` is how many still wait. A claim
    /// from before this process (it quit mid-response) is held again: its response was never written.
    public func takeHeld(agent: String, fits: ([Held]) -> Bool) throws -> (taken: [Held], remaining: Int) {
        try locked {
            var rows = try load()
            func waiting(_ exchange: AgentConversationExchange) -> Bool {
                exchange.status == "held"
                    || exchange.status == "delivering" && (exchange.settledAt ?? .distantPast) < AbandonedTurnReconciler.processEpoch
            }
            let all = rows.filter { $0.agent == agent }.flatMap { row in
                (row.exchanges ?? []).filter(waiting).compactMap { exchange in
                    exchange.prompt.map { Held(row: row.id, exchange: exchange.id, at: exchange.sentAt, text: $0, conversation: row.conversationID) }
                }
            }.sorted { $0.at < $1.at }
            var taken: [Held] = []
            for item in all {
                guard fits(taken + [item]) else { break }
                taken.append(item)
            }
            guard !taken.isEmpty else { return ([], all.count) }
            Self.mark(taken, in: &rows, from: waiting) { exchange, receipt in
                exchange.status = "delivering"
                exchange.settledAt = Date()
                receipt?["status"] = .string("delivering")
            }
            try save(rows)
            return (taken, all.count - taken.count)
        }
    }

    /// Settles what `takeHeld` handed out, once: delivered when the response carrying them was written, held again when it was not. Anything already settled is left as it is, so a late second word changes nothing.
    public func settleHeld(_ taken: [Held], written: Bool, to name: String, via tool: String) throws {
        guard !taken.isEmpty else { return }
        let now = Date()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        try locked {
            var rows = try load()
            Self.mark(taken, in: &rows, from: { $0.status == "delivering" }) { exchange, receipt in
                exchange.status = written ? "delivered" : "held"
                exchange.settledAt = written ? now : nil
                receipt?["status"] = .string(exchange.status)
                guard written else { return }
                receipt?["delivered"] = .bool(true)
                receipt?["accepted"] = .bool(true)
                receipt?["delivered_at"] = .string(ISO8601DateFormatter().string(from: now))
                receipt?["detail"] = .string("Delivered to \(name) at \(clock.string(from: now)), in the result of its \(tool) call. Its answer comes as a message of its own.")
            }
            if written {
                for item in taken {
                    guard let i = rows.firstIndex(where: { $0.id == item.row }),
                          rows[i].exchanges?.contains(where: { $0.id == item.exchange && $0.status == "delivered" }) == true else { continue }
                    // Taken by the host: that message's "accept" is kept (its answer comes as its own message).
                    var accepted = Experience.Obligation(to: "agent:" + rows[i].agent)
                    accepted.phase = .accepted
                    accepted.evidence = .init(source: "agents/conversations", id: rows[i].id)
                    rows[i].settledObligations = rows[i].settledObligations ?? [:]
                    rows[i].settledObligations?[item.exchange, default: [:]]["accept"] = accepted
                }
            }
            try save(rows)
        }
    }

    /// One edit to each named exchange still in the state `from` accepts, and to the conversation's receipt when it is the current send (whose exchange mirrors that receipt).
    private static func mark(_ items: [Held], in rows: inout [AgentConversationRecord],
                             from: (AgentConversationExchange) -> Bool,
                             _ edit: (inout AgentConversationExchange, inout [String: JSONValue]?) -> Void) {
        for item in items {
            guard let i = rows.firstIndex(where: { $0.id == item.row }),
                  let j = rows[i].exchanges?.firstIndex(where: { $0.id == item.exchange }),
                  let exchange = rows[i].exchanges?[j], from(exchange) else { continue }
            var changed = exchange
            var receipt: [String: JSONValue]? = nil
            if rows[i].operationID == item.exchange, case .object(let fields)? = rows[i].receipt { receipt = fields }
            edit(&changed, &receipt)
            rows[i].exchanges?[j] = changed
            if let receipt { rows[i].receipt = .object(receipt) }
            rows[i].updatedAt = Date()
        }
    }

    /// The accepted message id of the send waiting in exactly this conversation, for an answer that names the conversation, not the message.
    public func waitingMessage(agent: String, conversationID: String) throws -> String? {
        let identity = AgentContactIdentity(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        return try records().filter { identity.canonical($0.agent) == identity.canonical(agent) && $0.phase == "waiting" && $0.conversationID == conversationID }
            .max { ($0.operationStartedAt ?? $0.updatedAt) < ($1.operationStartedAt ?? $1.updatedAt) }
            .flatMap { if case .string(let id)? = $0.readInput?["message_id"], !id.isEmpty { id } else { nil } }
    }

    /// A contact's answer that came as a message of its own (Claude over the bridge) settles the send it names by its exact accepted message id, and only that one, through whichever of her doors it went; an answer naming nothing settles
    /// nothing. Returns whether a waiting send was settled. `landedIn`: the chat the answer itself arrived in; in the contact's own session it is already there. `from`/`steeredBy`: the answering turn's own stamp (its door, and the peers
    /// that steered it), carried onto any copy verbatim.
    @discardableResult public func settleReply(agent: String, messageID: String, text: String,
                                               landedIn: String? = nil, from: String, steeredBy: [String]) throws -> Bool {
        let identity = AgentContactIdentity(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        return try locked {
            var rows = try load()
            guard !messageID.isEmpty, let index = rows.firstIndex(where: {
                identity.canonical($0.agent) == identity.canonical(agent) && $0.phase == "waiting" && $0.readInput?["message_id"] == .string(messageID)
            }) else { return false }
            let before = rows[index]
            try answer(&rows[index], text: text, from: from, steeredBy: steeredBy)
            try save(rows)
            // Where the thread reader already reads it (any session of the record's identity), the original attested row is the reply: no copy.
            let reader = identity.owners(String(rows[index].agent.dropFirst(5))).map { ContactThread.prefix(owner: $0) }
            if !(landedIn.map { session in reader.contains { session.hasPrefix($0) } } ?? false) {
                noteReplies(was: before, now: rows[index], wake: false, from: from, steeredBy: steeredBy,
                            answer: (rows[index].operationID, text))
            }
            return true
        }
    }

    func answer(_ row: inout AgentConversationRecord, text: String, from: String, steeredBy: [String]) throws {
        var receipt: [String: JSONValue] = if case .object(let fields)? = row.receipt { fields } else { [:] }
        if case .array(var jobs)? = receipt["jobs"], jobs.count == 1, case .object(var job) = jobs[0] {
            job["agent_reply_text"] = .string(text)
            job["agent_reply_truncated"] = .bool(false)
            jobs[0] = .object(job); receipt["jobs"] = .array(jobs)
        } else {
            receipt["reply"] = .string(text)
            receipt["status"] = .string("answered")
        }
        receipt["reply_from"] = .string(from)
        receipt["reply_steered_by"] = .array(steeredBy.map(JSONValue.string))
        row.receipt = Self.cacheReceipt(.object(receipt))
        row.phase = "ready"
        row.automaticRead = false; row.nextReadAt = nil
        row.updatedAt = Date()
        try Self.absorbExchange(into: &row, file: fileURL)
    }

    /// Project already-read terminal owner evidence into waiting bookmarks. The existing delegation event runner supplies one complete snapshot; this never reads another store, sends, selects, or creates a conversation.
    @discardableResult public func reconcileDelegationReplies(_ jobs: [DelegationReadout]) throws -> Int {
        try locked {
            var rows = try load()
            var changed = 0
            var before: [(Int, AgentConversationRecord)] = []
            for index in rows.indices {
                let row = rows[index]
                guard ["waiting", "attention"].contains(row.phase), !row.automaticRead,
                      let lane = AgentConversationDelivery.lane(for: row.agent, dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent()),
                      row.readInput?["agent"] == .string(row.agent),
                      case .string(let messageID)? = row.readInput?["message_id"],
                      !messageID.isEmpty else { continue }
                // Match the accepted message, never an internal job ID, topic or newest record. Ambiguous retained/delivery evidence stays with its owner for an explicit read.
                let matches = jobs.filter { $0.agent == lane && $0.acceptedMessageIDs.contains(messageID) }
                guard matches.count == 1, let job = matches.first,
                      job.stallBasis == .terminal,
                      case .object(var result) = job.toJSON(includeReplyText: true) else { continue }
                result["matched_message_id"] = .string(messageID)
                let receipt = JSONValue.object(["status": .string("ok"), "jobs": .array([.object(result)])])
                var next = row
                AgentConversationSession.absorb(receipt, into: &next)
                // Only terminal transitions are written. In particular an unchanged/in-progress snapshot cannot self-trigger this file-watched runner, and a later read retains its full receipt. A live hand-off stays waiting (its answer is
                // a chat); its receipt is written once.
                guard (next.phase != "waiting" && next.phase != row.phase)
                        || (AgentConversationSession.liveHandOff(next) && !AgentConversationSession.liveHandOff(row)) else { continue }
                next.updatedAt = Date()
                try Self.absorbExchange(into: &next, file: fileURL)
                before.append((index, row))
                rows[index] = next
                changed += 1
            }
            if changed > 0 { try save(rows) }
            // A lane's answer here came back as a turn (or to its caller).
            for (index, row) in before { noteReplies(was: row, now: rows[index], wake: false, from: rows[index].agent) }
            return changed
        }
    }

    /// A built-in delegate's stall or bad outcome, for the send still owed an answer on it (its exact accepted message id), held for the continuation to tell her once in the chat it came from. A person's own send is theirs (their card says
    /// it). The same event again is no new notice; a newer one with nothing to tell (it moved again, or finished) withdraws one still waiting to be told.
    @discardableResult public func noteDelegationEvent(agent: String, messageIDs: [String],
                                                     notice: (AgentConversationRecord) -> AgentConversationNotice?) throws -> Int {
        try locked {
            var rows = try load()
            var changed = 0
            for index in rows.indices {
                let row = rows[index]
                guard row.agent == agent, case .string(let messageID)? = row.readInput?["message_id"],
                      messageIDs.contains(messageID) else { continue }
                let next = ["waiting", "attention", "ready"].contains(row.phase) && row.personInitiated != true ? notice(row) : nil
                guard row.notice != next, next == nil || row.notice?.event != next?.event else { continue }
                rows[index].notice = next
                rows[index].nextReadAt = nil
                changed += 1
            }
            if changed > 0 { try save(rows) }
            return changed
        }
    }

    /// Save the answer in its one conversation before making receipt/ledger excerpts. The locator names a row that was actually committed there.
    package func retainReply(_ receipt: JSONValue, for row: AgentConversationRecord,
                             exchange: String? = nil) async throws -> JSONValue {
        guard row.agent.hasPrefix("peer:"), case .object(var fields) = receipt,
              fields["reply_location"] == nil else { return receipt }
        let answer = AgentConversationExchange.answer(fields)
        guard let text = answer.text, !answer.truncated else { return receipt }
        var outcome = row
        AgentConversationSession.absorb(receipt, into: &outcome)
        guard outcome.phase != "waiting", outcome.phase != "sending" else { return receipt }
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let owner = String(row.agent.dropFirst(5)), id = exchange ?? row.operationID
        let identity = AgentContactIdentity(dataRoot: root)
        var line = try ContactThread.mergedLines(dataRoot: root, owner: owner, identity: identity)
            .last(where: { $0.answers == id && ContactThread.bridgedText($0.text) == ContactThread.bridgedText(text) })
        if line == nil {
            let from: String = if case .string(let source)? = fields["reply_from"] { source } else { row.agent }
            let steering: [String] = if case .array(let values)? = fields["reply_steered_by"] {
                values.compactMap { if case .string(let peer) = $0 { peer } else { nil } }
            } else { [] }
            let entry = ContactThread.Entry.reply(owner: owner, name: row.name, text: text,
                replyID: "agent-conversation:" + id, at: Date(), from: from, steeredBy: steering)
            try await Task.detached { try await ContactThread.attempt(entry, dataRoot: root) }.value
            line = try ContactThread.mergedLines(dataRoot: root, owner: owner, identity: identity).last(where: { $0.answers == id })
        }
        guard let line else {
            throw Failure(message: "The contact's answer was written but its conversation row could not be located.")
        }
        fields["reply_location"] = .object(["tool": .string("app"), "input": .object([
            "action": .string("agent.read"), "args": .object(["agent": .string(row.agent),
                "conversation": .string(row.id), "history_exchange": .string(line.id)])])])
        return .object(fields)
    }

    public static func cacheReceipt(_ value: JSONValue) -> JSONValue {
        if let data = try? JSONEncoder().encode(value), data.count <= 96 * 1024 { return value }
        guard case .object(let root) = value else { return value }
        func excerpt(_ fields: [String: JSONValue], textLimit: Int, remaining: inout Int) -> [String: JSONValue] {
            var result: [String: JSONValue] = ["receipt_truncated": .bool(true)]
            // Keep the original outcome and exact identities, never replace a successful answer with a synthetic receipt-size failure.
            for key in ["status", "run_status", "state", "conversation_id", "conversationId", "thread_id", "task_id",
                        "message_id", "messageId", "matched_message_id", "entry_id", "completed", "terminal", "sent",
                        "accepted", "read", "needs_input", "needs_authentication", "reply_state", "reason", "error",
                        "execution_error", "detail", "untrusted_remote_data", "background_send", "delivery", "reply_observation",
                        "reply_from", "replied_at", "ended_at", "approvalId", "filePath", "effects", "agent", "transport", "retention_error"] {
                guard var field = fields[key] else { continue }
                if ["detail", "error", "execution_error", "retention_error"].contains(key), case .string(let text) = field {
                    field = .string(AgentConversationExchange.clipped(text, limit: min(2048, textLimit)).text)
                }
                if let bytes = try? JSONEncoder().encode(field), bytes.count <= remaining {
                    result[key] = field; remaining -= bytes.count
                } else {
                    // An unusually large identity is omitted as a whole and named; a clipped ID could silently point to another task.
                    var omitted: [JSONValue] = if case .array(let values)? = result["omitted_fields"] { values } else { [] }
                    omitted.append(.string(key)); result["omitted_fields"] = .array(omitted)
                }
            }
            for key in ["reply_location", "read_with", "reply_steered_by"] {
                if let locator = fields[key], let bytes = try? JSONEncoder().encode(locator), bytes.count <= 8192 { result[key] = locator }
            }
            let answer = AgentConversationExchange.answer(fields)
            if let text = answer.text {
                let clipped = AgentConversationExchange.clipped(text, limit: textLimit)
                result["reply"] = .string(clipped.text)
                result["reply_truncated"] = .bool(clipped.truncated || answer.truncated)
            }
            return result
        }
        var limit = AgentConversationExchange.textLimit
        while true {
            var remaining = 40 * 1024
            var result = excerpt(root, textLimit: limit, remaining: &remaining)
            if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] {
                var bounded = excerpt(job, textLimit: limit, remaining: &remaining)
                bounded["agent_reply_text"] = bounded.removeValue(forKey: "reply")
                bounded["agent_reply_truncated"] = bounded.removeValue(forKey: "reply_truncated")
                result["jobs"] = .array([.object(bounded)])
                result.removeValue(forKey: "reply"); result.removeValue(forKey: "reply_truncated")
            }
            let receipt = JSONValue.object(result)
            // JSON escaping can expand text well beyond its UTF-8 byte count.
            if limit == 0 || ((try? JSONEncoder().encode(receipt).count) ?? 0) <= 96 * 1024 { return receipt }
            limit /= 2
        }
    }

    static func absorbExchange(into row: inout AgentConversationRecord, file: URL) throws {
        guard row.phase != "sending", var history = row.exchanges,
              let index = history.firstIndex(where: { $0.id == row.operationID }) else { return }
        history[index].absorb(row)
        row.exchanges = try AgentConversationExchange.bounded(history, file: file)
    }
}
