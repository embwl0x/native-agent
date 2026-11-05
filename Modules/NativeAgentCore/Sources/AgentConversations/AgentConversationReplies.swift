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
    /// Contact news waits in the shared held owner, independently of any caller's open task.
    public static let heldReplySurface = "agent-held"

    /// Store settled replies in the contact session unless handover already carries them there. Preserve the transport-attested speaker and steering stamp;
    /// person-initiated sends must not wake the agent.
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
                    // Detach from the writer’s turn context.
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

    /// Claim replies by exact send, or the sole delivered held send in the named conversation. The draining call cannot answer its still-delivering exchange.
    /// Claim and deadline release share one lock.
    public func offerBridgeReplyToInlineWait(agent: String, messageID: String? = nil,
                                             conversationID: String? = nil, text: String,
                                             from: String, steeredBy: [String]) throws -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let identity = try AgentContactIdentity(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
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
                return true
            }
            guard AgentConversationRunning.shared.watched(before.id),
                  before.phase == "waiting" || AgentConversationSession.heldReplyPending(before) else { return false }
            try answer(&rows[index], text: text, from: from, steeredBy: steeredBy)
            rows[index].shownInline = before.operationID + ":ready"
            rows[index].deliveryState = nil
            try save(rows)
            noteReplies(was: before, now: rows[index], wake: false, from: from,
                        steeredBy: steeredBy, answer: (before.operationID, text))
            return true
        }
    }

    /// A saved send can be held without a live turn. The transcript owns its payload; repeats never write another exchange.
    public func holdReply(peer: AgentPeerContact, session: String, sendID: String, text: String) throws {
        guard session.hasPrefix(ContactThread.prefix(owner: peer.id)), UUID(uuidString: sendID) != nil else {
            throw Failure(message: "The held answer does not name this contact's conversation and send identity.")
        }
        try Self.validateHeldText(text)
        try locked {
            var rows = try load()
            let agent = "peer:" + peer.id
            let existing = rows.filter { (($0.exchanges ?? []) + ($0.releasing ?? [])).contains { $0.id == sendID } }
            if !existing.isEmpty {
                guard existing.count == 1, existing[0].agent == agent else {
                    throw Failure(message: "The held answer's exchange identity is ambiguous; repair its saved record.")
                }
                return
            }
            let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
            let messages = try ContactThread.lines(dataRoot: root, owner: peer.id).filter { $0.sendID == sendID && $0.mine }
            guard messages.count == 1, let message = messages.first, try Self.heldText(message) == text else {
                throw Failure(message: "The held answer has no unique matching contact send row; repair its transcript.")
            }
            // Pruning publishes an exchange's terminal state on this very send row before releasing its journal entry.
            if message.sendState != nil { return }
            let conversation = "mcp-" + peer.id
            guard rows.count < 512 else { throw Failure(message: "The saved conversation limit has been reached; the answer stays saved.") }
            var row = AgentConversationRecord(id: sendID, scopeSessionID: session, agent: agent, name: peer.name,
                label: "News " + String(sendID.prefix(8)), conversationID: conversation, phase: "ready", operationID: sendID, updatedAt: message.at,
                sourceSurface: "agent-bridge", operationStartedAt: message.at, expectsReply: false)
            let life = try DataRootLife.current(in: root)
            var exchange = AgentConversationExchange.started(operationID: sendID, at: message.at, message: text)
            exchange.lifeID = life
            exchange.phase = "ready"; exchange.status = "held"
            row.exchanges = try AgentConversationExchange.bounded([exchange], file: fileURL)
            row.updatedAt = Date()
            row.lifeID = life
            row.peerRouteFingerprint = Self.routeFingerprint(peer)
            row.receipt = .object(["status": .string("held"), "conversation_id": .string(conversation), "delivered": .bool(false)])
            rows.append(row)
            try save(rows)
        }
    }

    package static func validateHeldText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "The answer has no words or files to hold; nothing was held.")
        }
        guard text.utf8.count <= AgentConversationExchange.textLimit else {
            throw Failure(message: "Nothing was held: a contact's held message keeps at most \(AgentConversationExchange.textLimit / 1024) KiB. "
                + "The answer was not truncated.")
        }
    }

    package static func heldText(_ message: ContactThread.Line) throws -> String {
        var text = message.text
        if let boundary = message.metadata["workingCommentaryChars"] {
            guard case .int(let cut) = boundary, let count = Int(exactly: cut), count >= 0, count <= text.count else {
                throw Failure(message: "The held answer's commentary boundary is unreadable; repair its saved row.")
            }
            text = String(text.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var paths: [String] = []
        if let value = message.metadata["attachments"] {
            guard case .array(let files) = value else { throw Failure(message: "The held answer's saved attachments are unreadable.") }
            paths = try files.map { file in
                guard case .object(let fields) = file, let path = fields["path"]?.stringValue, !path.isEmpty else {
                    throw Failure(message: "A held answer attachment has no saved file reference; restore it before delivery.")
                }
                return path
            }
        }
        return heldText(text, filePaths: paths)
    }

    package static func heldText(_ text: String, filePaths: [String]) -> String {
        filePaths.isEmpty ? text : text + "\n\nFiles:\n" + filePaths.joined(separator: "\n")
    }

    /// Pull-host messages leave only through that host’s next call.
    public struct Held: Sendable {
        public let row: String
        public let exchange: String
        public let at: Date
        public let text: String
        public let conversation: String?
    }

    /// Claim held messages oldest-first in one serialized write so concurrent drains cannot take the same message. A claim interrupted before its response was
    /// written remains held.
    public func takeHeld(agent: String, fits: ([Held]) -> Bool) throws -> (taken: [Held], remaining: Int) {
        try locked {
            var rows = try load()
            func waiting(_ exchange: AgentConversationExchange) -> Bool {
                exchange.status == "held"
                    || exchange.status == "delivering" && (exchange.settledAt ?? .distantPast) < AbandonedTurnReconciler.processEpoch
            }
            // The canonical contact transcript owns the accepted message. The exchange's bounded prompt is presentation only, never payload.
            let pending = rows.filter { $0.agent == agent && ($0.exchanges ?? []).contains(where: waiting) }
            guard !pending.isEmpty else { return ([], 0) }
            guard agent.hasPrefix("peer:") else { throw Failure(message: "A held send requires its exact contact identity.") }
            let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
            let lines = try ContactThread.lines(dataRoot: root, owner: String(agent.dropFirst(5)))
            let all = try pending.flatMap { row in
                try (row.exchanges ?? []).filter(waiting).map { exchange in
                    let messages = lines.filter { $0.sendID == exchange.id && $0.mine }
                    guard messages.count == 1, let message = messages.first else {
                        throw Failure(message: """
                            Held message \(exchange.id) has no unique canonical payload; repair its contact transcript before delivery. Nothing was \
                            drained.
                            """)
                    }
                    return Held(row: row.id, exchange: exchange.id, at: exchange.sentAt,
                        text: try Self.heldText(message), conversation: row.conversationID)
                }
            }.sorted { $0.at < $1.at }
            var taken: [Held] = []
            for item in all {
                guard fits(taken + [item]) else {
                    if taken.isEmpty { throw Failure(
                        message: "Held message \(item.exchange) exceeds this host's response capacity. It remains held in full; nothing was drained.") }
                    break
                }
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

    /// What one door call carries out to a contact: the held messages it took, how many still wait, and how it settles them once its response is
    /// written or fails. Every agent door drains through this one owner; a door never keeps its own held list.
    public struct HeldDrain: Sendable {
        public let taken: [Held]
        public let remaining: Int
        public let settle: @Sendable (_ written: Bool) -> Void
        public static let nothing = HeldDrain(taken: [], remaining: 0, settle: { _ in })
    }

    /// Drain what is held for one contact (`peer`, the contact's id without its `peer:` prefix) into the response a door is about to write. The door
    /// calls `settle` with whether that response was written; a settlement that fails owes repair and never resends.
    public func drainHeld(peer: String, name: String, via door: String, fits: ([Held]) -> Bool) throws -> HeldDrain {
        let held = try takeHeld(agent: "peer:" + peer, fits: fits)
        guard !held.taken.isEmpty else { return HeldDrain(taken: [], remaining: held.remaining, settle: { _ in }) }
        let taken = held.taken
        let dataRoot = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let file = fileURL
        let settle: @Sendable (Bool) -> Void = { written in
            do { try AgentConversationStore(dataRoot: dataRoot).settleHeld(taken, written: written, to: name, via: door) }
            catch {
                let words = "Held message settlement failed: " + error.localizedDescription
                    + "; response written: \(written); exchanges: " + taken.map(\.exchange).joined(separator: ", ")
                RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .message, operation: "agent.held.settle:" + peer, owner: file.path,
                    words: words, lever: "Repair the saved delivery transition against its original response outcome before any resend.",
                    nextCall: ToolFailureError.call("app", ["action": .string("agent.read"), "args": .object(["agent": .string("peer:" + peer)])]))
            }
        }
        return HeldDrain(taken: taken, remaining: held.remaining, settle: settle)
    }

    /// Only a written response proves held-message delivery; settlement is idempotent against late callbacks.
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
                receipt?["detail"] = .string(
                    "Delivered to \(name) at \(clock.string(from: now)), in the result of its \(tool) call. Its answer comes as a message of its own.")
            }
            if written {
                for item in taken {
                    guard let i = rows.firstIndex(where: { $0.id == item.row }),
                          rows[i].exchanges?.contains(where: { $0.id == item.exchange && $0.status == "delivered" }) == true else { continue }
                    // Keep acceptance after the host takes the message; its answer arrives separately.
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

    /// Update only exchanges in the expected state; mirror the current send’s receipt in the same edit.
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

    public func waitingMessage(agent: String, conversationID: String) throws -> String? {
        let identity = try AgentContactIdentity(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        return try records().filter { identity.canonical($0.agent) == identity.canonical(agent) && $0.phase == "waiting"
            && $0.conversationID == conversationID }
            .map { row -> (row: AgentConversationRecord, started: Date) in
                guard let started = row.operationStartedAt else {
                    throw Failure(
                        message: "Conversation \(row.id) has no operation start time; repair its retained evidence before selecting a waiting message.")
                }
                return (row, started)
            }
            .max { $0.started < $1.started }
            .flatMap { if case .string(let id)? = $0.row.readInput?["message_id"], !id.isEmpty { id } else { nil } }
    }

    /// An unsolicited bridge answer settles only the exact accepted message it names. Avoid copying an answer already in the contact’s session; preserve its
    /// attested speaker and steering stamp verbatim.
    @discardableResult public func settleReply(agent: String, messageID: String, text: String,
                                               landedIn: String? = nil, from: String, steeredBy: [String]) throws -> Bool {
        let identity = try AgentContactIdentity(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
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
        receipt["reply"] = .string(text)
        receipt["status"] = .string("answered")
        receipt["reply_from"] = .string(from)
        receipt["reply_steered_by"] = .array(steeredBy.map(JSONValue.string))
        row.receipt = Self.cacheReceipt(.object(receipt))
        row.phase = "ready"
        row.automaticRead = false; row.nextReadAt = nil
        row.updatedAt = Date()
        try Self.absorbExchange(into: &row, file: fileURL)
    }

    /// Notify the asking chat once for the exact send still owed an answer; a person’s own send remains theirs. Withdraw pending notices when newer evidence
    /// clears the fault, and never duplicate unchanged notices.
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
        let identity = try AgentContactIdentity(dataRoot: root)
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
            let result = excerpt(root, textLimit: limit, remaining: &remaining)
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
