import AgentWorkspace
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnContracts



extension AgentConversationRecord {
    /// Whether the current send is owed an answer; older records are judged
    /// from their prompt.
    public var awaitsReply: Bool {
        expectsReply ?? Self.expectsReply(explicit: nil, text: exchanges?.last { $0.id == operationID }?.prompt)
    }

    /// The sender's word wins (`expects_reply`). Otherwise every message
    /// expects an answer, except one that is nothing but a short
    /// acknowledgement ("thanks", "ok, got it", "done ✅", "noted").
    public static func expectsReply(explicit: Bool?, text: String?) -> Bool {
        if let explicit { return explicit }
        guard let text = text?.lowercased(), !text.contains("?") else { return true }
        let words = text.split { !$0.isLetter && $0 != "'" }.map(String.init)
        let acknowledgement: Set<String> = ["thanks", "thank", "you", "ty", "ok", "okay", "got", "it", "done", "noted",
                                            "received", "ack", "acknowledged", "great", "perfect", "cool", "confirmed",
                                            "sounds", "good", "all", "set", "will", "do", "much", "appreciated"]
        return words.isEmpty || words.count > 6 || !words.allSatisfy(acknowledgement.contains)
    }
}

/// Where a contact's current send stands, from evidence the lanes already
/// keep: sending → delivered → read → answered, or failed. `waiting` is a
/// send the lane is still carrying, or one handed over whose asked-for
/// answer is still owed. Nothing here times out.
public enum AgentConversationDelivery: String, Sendable {
    case sending, waiting, delivered, read, answered, failed, notDelivered

    /// `read`: the recipient's inbox marked this send read.
    public static func of(_ row: AgentConversationRecord, read: Bool) -> Self {
        if row.phase != "sending", row.exchanges?.last(where: { $0.id == row.operationID })?.reply != nil { return .answered }
        switch row.phase {
        case "sending": return .sending
        case "attention":
            if case .object(let receipt)? = row.receipt, receipt["sent"] == .bool(false) || receipt["error"] != nil
                || receipt["status"] == .string("outcome_unknown") { return .notDelivered }
            return row.awaitsReply ? .failed : (read ? .read : .delivered)
        case "waiting":
            // Still with the lane (queued, running, a peer's task at work): the
            // lane itself brings the answer. Handed into a live session and done
            // there (Claude): an answer is owed only if one was asked for.
            guard AgentConversationSession.liveHandOff(row), !row.awaitsReply else { return .waiting }
            return read ? .read : .delivered
        default: return read ? .read : .delivered
        }
    }

    /// A built-in lane's inbox, where the recipient marks a message read.
    public static func inbox(agent: String, bridgeConfigRoot root: URL) -> URL? {
        switch agent {
        case "claude": root.appendingPathComponent("claude-bridge/claude-inbox.jsonl")
        case "codex": root.appendingPathComponent("codex-nativeagent-bridge/codex-inbox.jsonl")
        case "omp": root.appendingPathComponent("omp-bridge/omp-inbox.jsonl")
        default: nil
        }
    }
}

public enum AgentConversationContext {
    /// Suppresses only the conversational facade for an owner recovery read,
    /// or for a queued send resumed after a restart (the facade already owns
    /// that send). The complete original tool permission chain still executes.
    @TaskLocal public static var isInternalRead = false
}

public struct AgentConversationStore: Sendable {
    public let fileURL: URL
    public init(dataRoot: URL) { fileURL = dataRoot.appendingPathComponent("agents/conversations.json") }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        package init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public func records() throws -> [AgentConversationRecord] {
        try locked {
            var rows = try load()
            if try reconcileDeniedApprovals(&rows) { try save(rows) }
            try? AgentConversationLiveStore(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent()).merge([])
            return rows
        }
    }

    /// Read-only and without the lock, for a glance that must not wait; a
    /// file caught mid-write fails to decode and throws.
    public func recordsUnlocked() throws -> [AgentConversationRecord] { try load() }

    public func find(scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        let rows = try records()
        return try select(rows, scope: scopeSessionID, agent: agent, label: label)
            ?? Self.continuing(rows, agent: agent, label: label)
    }

    /// A contact's conversation is the agent's, not one chat's (User 09-22):
    /// when this chat has none, the newest main thread from any chat is the
    /// one to continue, so "pull up Codex" lands on the real discussion.
    static func continuing(_ rows: [AgentConversationRecord], agent: String, label: String?) -> AgentConversationRecord? {
        rows.filter { row in
            guard row.agent == agent else { return false }
            if let label { return row.label.caseInsensitiveCompare(label) == .orderedSame }
            return row.label == "Main" || row.selected
        }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Reserve before dispatch. Never run two messages against one bookmark.
    /// A crash leaves a visible uncertain send, never permission to replay it.
    public func begin(scopeSessionID: String, agent: String, name: String, label: String?, record: String? = nil,
                      fresh: Bool, sourceSurface: String, fingerprint: String?,
                      replyRoute: [String: String]?, message: String? = nil,
                      legacyFingerprints: [String] = [], personInitiated: Bool = false,
                      supersedeWaiting: Bool = false, expectsReply: Bool? = nil,
                      reservation: String? = nil) throws -> AgentConversationRecord {
        guard !scopeSessionID.isEmpty, scopeSessionID.utf8.count <= 256,
              label == nil || (label!.count <= 120 && !label!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw Failure(message: "Choose a short conversation name.")
        }
        return try locked {
            var rows = try load()
            if try reconcileDeniedApprovals(&rows) { try save(rows) }
            // The exact record the caller resolved (by id) is the one continued.
            let old = try record.flatMap { id in rows.first { $0.id == id && $0.agent == agent } }
                ?? select(rows, scope: scopeSessionID, agent: agent, label: label)
                ?? (fresh ? nil : Self.continuing(rows, agent: agent, label: label))
            // An accepted ask its peer never answered (Grok Bot) may be superseded;
            // an unsettled send never is.
            if !fresh, let old, old.phase == "sending" || (old.phase == "waiting" && !supersedeWaiting) {
                throw Failure(message: "This conversation is still waiting for its previous message. Open it to see the current state; do not send that message again.")
            }
            // A queued message taken to go next keeps its place. Its own send
            // begins only while it is still reserved and still queued (not withdrawn).
            if !fresh, let old, let held = old.queueReservation, held != reservation {
                throw Failure(message: "A queued message on this conversation is going first; send again to queue behind it.")
            }
            if let reservation, fresh || old?.queueReservation != reservation
                || old?.queued?.contains(where: { $0.id == reservation }) != true {
                throw Failure(message: "That queued message was withdrawn before it went; nothing was sent.")
            }
            if !fresh, let old, old.peerRouteFingerprint != fingerprint,
               old.peerRouteFingerprint.map(legacyFingerprints.contains) != true {
                throw Failure(message: "This contact's connection changed. Start a separate conversation explicitly; the existing conversation has been preserved.")
            }
            if fresh, label != nil, old != nil {
                throw Failure(message: "That conversation name is already in use. Choose a different name for a separate conversation.")
            }
            var row: AgentConversationRecord
            if !fresh, let old {
                row = old
                // Continuing from another chat moves the thread here, like
                // dragging a window onto the desktop that is in front.
                row.scopeSessionID = scopeSessionID
            } else {
                guard rows.count < 512 else { throw Failure(message: "The saved conversation limit has been reached.") }
                let id = UUID().uuidString.lowercased()
                row = AgentConversationRecord(id: id, scopeSessionID: scopeSessionID, agent: agent, name: name,
                    label: label ?? (fresh ? "Conversation " + String(id.prefix(8)) : "Main"),
                    phase: "ready", operationID: id, updatedAt: Date(), sourceSurface: sourceSurface)
            }
            try Self.absorbExchange(into: &row)
            row.operationID = UUID().uuidString.lowercased()
            row.phase = "sending"
            row.updatedAt = Date()
            row.operationStartedAt = row.updatedAt
            row.exchanges = try AgentConversationExchange.bounded((row.exchanges ?? []) + [
                .started(operationID: row.operationID, at: row.updatedAt, message: message, byPerson: personInitiated)
            ])
            row.personInitiated = personInitiated ? true : nil
            row.expectsReply = expectsReply
            row.sourceSurface = sourceSurface
            row.peerRouteFingerprint = fingerprint
            row.replyRoute = replyRoute
            row.automaticRead = false
            row.readInput = nil
            row.deliveryState = nil
            row.deliveryRunID = nil
            row.nextReadAt = nil
            row.stop = nil
            row.notice = nil
            if let reservation, row.queueReservation == reservation {
                row.queued?.removeAll { $0.id == reservation }
                if row.queued?.isEmpty == true { row.queued = nil }
            }
            row.queueReservation = nil
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i] = row }
            else { rows.append(row) }
            try save(rows)
            return row
        }
    }

    /// Queue a follow-up on a thread whose reply is still in flight. Nil when
    /// the reply settled meanwhile (the caller sends it normally instead).
    public func enqueue(id: String, text: String, byPerson: Bool,
                        stillInFlight: (AgentConversationRecord) -> Bool) throws -> (AgentConversationRecord, AgentConversationQueued)? {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), stillInFlight(rows[i]) else { return nil }
            guard (rows[i].queued ?? []).count < 20 else {
                throw Failure(message: "Twenty messages are already queued on this conversation; nothing more was added.")
            }
            let item = AgentConversationQueued(id: UUID().uuidString.lowercased(), text: text, queuedAt: Date(),
                                               byPerson: byPerson ? true : nil)
            rows[i].queued = (rows[i].queued ?? []) + [item]
            rows[i].updatedAt = Date()
            try save(rows)
            return (rows[i], item)
        }
    }

    /// Take a queued follow-up off its thread to send it: only the oldest one
    /// still waiting, and only once `ready` says the thread has settled. The
    /// thread stays reserved for it until its `begin` (or `releaseReservation`),
    /// so nothing else can start in between.
    public func takeQueued(id: String, item: String, ready: (AgentConversationRecord) -> Bool) throws -> AgentConversationQueued? {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].queueReservation == nil, ready(rows[i]),
                  let head = rows[i].queued?.first(where: { $0.held == nil }), head.id == item else { return nil }
            // It stays queued (and visible) until its `begin` takes it off.
            rows[i].queueReservation = item
            try save(rows)
            return head
        }
    }

    /// Ends a reservation its send never used. True when it was still held,
    /// meaning that message did not begin.
    public func releaseReservation(id: String, item: String) throws -> Bool {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].queueReservation == item else { return false }
            rows[i].queueReservation = nil
            try save(rows)
            return true
        }
    }

    /// Put a follow-up back, first in line, marked with why it did not go.
    public func holdQueued(id: String, item: AgentConversationQueued, reason: String) throws {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
            var held = item
            held.held = reason
            rows[i].queued = [held] + (rows[i].queued ?? []).filter { $0.id != item.id }
            rows[i].updatedAt = Date()
            try save(rows)
        }
    }

    /// A late answer to an earlier exchange (its thread has moved on since)
    /// lands on that exchange, never on the current one.
    public func settleExchange(id: String, exchange: String, reply: String) throws {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), var history = rows[i].exchanges,
                  let j = history.firstIndex(where: { $0.id == exchange }), history[j].reply == nil else { return }
            let text = AgentConversationExchange.clipped(reply, limit: AgentConversationExchange.textLimit)
            history[j].reply = text.text; history[j].replyTruncated = text.truncated
            history[j].status = "answered"; history[j].phase = "ready"; history[j].settledAt = Date()
            rows[i].exchanges = try AgentConversationExchange.bounded(history)
            try save(rows)
        }
    }

    /// Withdraw every follow-up still queued (`agent_cancel` clear_queue).
    @discardableResult public func clearQueued(id: String) throws -> Int {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return 0 }
            let count = rows[i].queued?.count ?? 0
            // A reserved message is withdrawn too: its sender's begin then refuses.
            let reserved = rows[i].queueReservation != nil
            rows[i].queued = nil
            rows[i].queueReservation = nil
            if count > 0 || reserved { rows[i].updatedAt = Date(); try save(rows) }
            return count
        }
    }

    /// `touch: false` (a read) moves updatedAt only when the phase or the
    /// newest reply changed, so opening a conversation never reads as news.
    @discardableResult public func update(id: String, operationID: String, touch: Bool = true,
        edit: (inout AgentConversationRecord) throws -> Void) throws -> AgentConversationRecord {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id && $0.operationID == operationID }) else {
                throw Failure(message: "This conversation has moved on; the older result was not applied.")
            }
            let identity = rows[i]
            try edit(&rows[i])
            guard rows[i].id == identity.id, rows[i].agent == identity.agent,
                  rows[i].scopeSessionID == identity.scopeSessionID,
                  rows[i].operationID == operationID else { throw Failure(message: "Conversation identity cannot change.") }
            try Self.absorbExchange(into: &rows[i])
            if touch || rows[i].phase != identity.phase || rows[i].exchanges?.last?.reply != identity.exchanges?.last?.reply {
                rows[i].updatedAt = Date()
            }
            if rows[i].selected {
                for j in rows.indices where j != i && rows[j].scopeSessionID == rows[i].scopeSessionID && rows[j].agent == rows[i].agent {
                    rows[j].selected = false
                }
            }
            try save(rows)
            return rows[i]
        }
    }

    /// The accepted message id of the send waiting in exactly this
    /// conversation, for an answer that names the conversation, not the message.
    public func waitingMessage(agent: String, conversationID: String) throws -> String? {
        try records().filter { $0.agent == agent && $0.phase == "waiting" && $0.conversationID == conversationID }
            .max { ($0.operationStartedAt ?? $0.updatedAt) < ($1.operationStartedAt ?? $1.updatedAt) }
            .flatMap { if case .string(let id)? = $0.readInput?["message_id"], !id.isEmpty { id } else { nil } }
    }

    /// A contact's answer that came as a message of its own (Claude over the
    /// bridge) settles the send it names by its exact accepted message id, and
    /// only that one; an answer naming nothing settles nothing. Returns whether
    /// a waiting send was settled.
    @discardableResult public func settleReply(agent: String, messageID: String, text: String) throws -> Bool {
        try locked {
            var rows = try load()
            guard !messageID.isEmpty, let index = rows.firstIndex(where: {
                $0.agent == agent && $0.phase == "waiting" && $0.readInput?["message_id"] == .string(messageID)
            }) else { return false }
            let limit = AgentConversationExchange.textLimit
            let reply = JSONValue.string(String(text.prefix(limit)))
            var root: [String: JSONValue] = if case .object(let fields)? = rows[index].receipt { fields } else { [:] }
            if case .array(var jobs)? = root["jobs"], jobs.count == 1, case .object(var job) = jobs[0] {
                job["agent_reply_text"] = reply
                job["agent_reply_truncated"] = .bool(text.count > limit)
                jobs[0] = .object(job)
                root["jobs"] = .array(jobs)
            } else { root["reply"] = reply }
            rows[index].receipt = Self.cacheReceipt(.object(root))
            rows[index].phase = "ready"
            rows[index].automaticRead = false
            rows[index].nextReadAt = nil
            rows[index].updatedAt = Date()
            try Self.absorbExchange(into: &rows[index])
            try save(rows)
            return true
        }
    }

    /// Project already-read terminal owner evidence into waiting bookmarks.
    /// The existing delegation event runner supplies one complete snapshot;
    /// this never reads another store, sends, selects, or creates a conversation.
    @discardableResult public func reconcileDelegationReplies(_ jobs: [DelegationJobProjection]) throws -> Int {
        try locked {
            var rows = try load()
            var changed = 0
            for index in rows.indices {
                let row = rows[index]
                guard ["waiting", "attention"].contains(row.phase), !row.automaticRead,
                      ["codex", "claude", "omp"].contains(row.agent),
                      row.readInput?["agent"] == .string(row.agent),
                      case .string(let messageID)? = row.readInput?["message_id"],
                      !messageID.isEmpty else { continue }
                // Match the accepted message, never an internal job ID, topic
                // or newest record. Ambiguous retained/delivery evidence stays
                // with its owner for an explicit read.
                let matches = jobs.filter { $0.agent == row.agent && $0.acceptedMessageIDs.contains(messageID) }
                guard matches.count == 1, let job = matches.first,
                      job.stallBasis == .terminal,
                      case .object(var result) = job.toJSON(includeReplyText: true) else { continue }
                result["matched_message_id"] = .string(messageID)
                let receipt = JSONValue.object(["status": .string("ok"), "jobs": .array([.object(result)])])
                var next = row
                AgentConversationSession.absorb(receipt, into: &next)
                // Only terminal transitions are written. In particular an
                // unchanged/in-progress snapshot cannot self-trigger this
                // file-watched runner, and a later read retains its full receipt.
                // A live hand-off stays waiting (its answer is a chat); its receipt is written once.
                guard (next.phase != "waiting" && next.phase != row.phase)
                        || (AgentConversationSession.liveHandOff(next) && !AgentConversationSession.liveHandOff(row)) else { continue }
                next.updatedAt = Date()
                try Self.absorbExchange(into: &next)
                rows[index] = next
                changed += 1
            }
            if changed > 0 { try save(rows) }
            return changed
        }
    }

    /// A built-in delegate's stall or bad outcome, for the send still owed an
    /// answer on it (its exact accepted message id), held for the continuation
    /// to tell her once in the chat it came from. A person's own send is theirs
    /// (their card says it). The same event again is no new notice; a newer
    /// one with nothing to tell (it moved again, or finished) withdraws one
    /// still waiting to be told.
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

    // 2026-09-22 WHY: the program path is not the route. An auto-updated
    // Hermes/Cursor/Goose reconnects at a new path and keeps its threads;
    // the reconnect itself still pins and verifies the new program.
    // 2026-09-26: the chat and workspace are the route too (AgentPeerStore.sameRoute).
    public static func routeFingerprint(_ peer: AgentPeerContact) -> String {
        fingerprint(peer, program: "", full: true)
    }

    /// Rows saved before 2026-09-22 also hashed the program path; rows saved
    /// before 2026-09-26 left out the chat and workspace. Both still continue.
    public static func sameRoute(_ saved: String?, _ peer: AgentPeerContact?) -> Bool {
        guard let peer else { return saved == nil }
        return saved == routeFingerprint(peer) || saved.map(legacyRouteFingerprints(peer).contains) == true
    }

    static func legacyRouteFingerprints(_ peer: AgentPeerContact) -> [String] {
        [fingerprint(peer, program: ""), fingerprint(peer, program: peer.approvedExecutablePath ?? "")]
    }

    private static func fingerprint(_ peer: AgentPeerContact, program: String, full: Bool = false) -> String {
        let fields = [peer.transport.rawValue, peer.endpoint.absoluteString, peer.acpWorkingDirectory ?? "", program]
            + (full ? [peer.conversationLabel ?? "", peer.hostWorkspace ?? ""] : [])
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func cacheReceipt(_ value: JSONValue) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), data.count <= 96 * 1024 else {
            return .object(["status": .string("receipt_too_large"),
                "detail": .string("The full result remains with its original owner. Open the conversation to recover it.")])
        }
        return value
    }

    private static func absorbExchange(into row: inout AgentConversationRecord) throws {
        guard row.phase != "sending", var history = row.exchanges,
              let index = history.firstIndex(where: { $0.id == row.operationID }) else { return }
        history[index].absorb(row)
        row.exchanges = try AgentConversationExchange.bounded(history)
    }

    /// Heal decisions already saved before this process saw them, including
    /// a denial racing a queued follow-up's begin. Approval storage is checked;
    /// unavailable authority leaves the exchange untouched.
    private func reconcileDeniedApprovals(_ rows: inout [AgentConversationRecord]) throws -> Bool {
        let held = rows.indices.filter {
            guard rows[$0].phase == "attention", case .object(let receipt)? = rows[$0].receipt else { return false }
            return receipt["approvalId"] != nil && ["waiting_approval", "waiting_for_approval", "waiting for approval",
                "approval_filed", "approval_required"].contains(receipt["status"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "")
        }
        guard !held.isEmpty,
              let decisions = try? SwiftNativeApprovalInbox.loadApprovalRowsChecked(
                at: fileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workflows/approvals/requests.json")) else { return false }
        var changed = false
        for i in held {
            guard case .object(let receipt)? = rows[i].receipt,
                  let decision = decisions.first(where: { if case .object(let value) = $0 { value["id"] == receipt["approvalId"] } else { false } }),
                  case .object(let approval) = decision, approval["status"] == .string("resolved"),
                  case .string(let status)? = approval["decision"], ["denied", "canceled"].contains(status) else { continue }
            let outcome: ToolNotRunStatus = status == "denied" ? .personDenied : .approvalCanceled
            rows[i].receipt = .object(["status": .string(status), "sent": .bool(false), "completed": .bool(false),
                "approvalId": receipt["approvalId"]!, "detail": .string(outcome.sentence())])
            rows[i].phase = "ready"; rows[i].automaticRead = false; rows[i].nextReadAt = nil; rows[i].deliveryState = nil
            // Keep its own time: settling an old denial must not make it the
            // contact's newest send (it hid newer replies behind "denied").
            try Self.absorbExchange(into: &rows[i])
            changed = true
        }
        return changed
    }

    private func select(_ rows: [AgentConversationRecord], scope: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        let matches = rows.filter { $0.scopeSessionID == scope && $0.agent == agent }
        if let label { return matches.first { $0.label.caseInsensitiveCompare(label) == .orderedSame } }
        if let selected = matches.first(where: { $0.selected }) { return selected }
        guard matches.count <= 1 else {
            throw Failure(message: "Choose a conversation: " + matches.map(\.label).joined(separator: ", "))
        }
        return matches.first
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(fileURL, work)
    }
    private func load() throws -> [AgentConversationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 50 * 1024 * 1024 else { throw Failure(message: "Saved conversations are too large to read safely.") }
        let rows = try JSONDecoder().decode([AgentConversationRecord].self, from: data)
        guard rows.count <= 512, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.operationID) != nil && !$0.scopeSessionID.isEmpty }) else {
            throw Failure(message: "Saved conversations are unavailable; existing records were preserved.")
        }
        for row in rows { try AgentConversationExchange.validate(row.exchanges) }
        return rows
    }
    private func save(_ rows: [AgentConversationRecord]) throws {
        for row in rows { try AgentConversationExchange.validate(row.exchanges) }
        let data = try JSONEncoder().encode(rows)
        guard data.count <= 50 * 1024 * 1024 else {
            throw Failure(message: "Saved conversations exceed their storage limit; existing records were preserved.")
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
        try? AgentConversationLiveStore(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent()).merge([])
        AgentConversationRunning.shared.changed() // wakes queued follow-ups
    }
}

extension AgentConversationStore {
    /// The contact's newest retained exchange in words ("last answered 06:31",
    /// "last send unavailable 03:17 — …"), across every chat. Nil when none is
    /// retained. Keyed by peer id, in one pass over the records.
    public static func lastExchanges(peers: [AgentPeerContact],
                                     records: [AgentConversationRecord]) -> [String: (summary: String, count: Int)] {
        var byPeer: [String: [AgentConversationRecord]] = [:]
        for row in records where row.agent.hasPrefix("peer:") {
            let id = String(row.agent.dropFirst(5))
            if peers.contains(where: { $0.id == id }) { byPeer[id, default: []].append(row); continue }
            // A contact reconnected under a new id keeps its old records, only
            // when exactly one current contact has that name and the same route.
            let named = peers.filter { $0.name.caseInsensitiveCompare(row.name) == .orderedSame }
            // Only a fingerprint that carries the whole route proves it; older ones stay unmatched.
            if named.count == 1, row.peerRouteFingerprint == routeFingerprint(named[0]) {
                byPeer[named[0].id, default: []].append(row)
            }
        }
        return byPeer.compactMapValues(summary)
    }

    private static func summary(_ rows: [AgentConversationRecord]) -> (summary: String, count: Int)? {
        let all = rows.flatMap { row in (row.exchanges ?? []).map { (row, $0) } }
        guard let (row, last) = all.max(by: { ($0.1.settledAt ?? $0.1.sentAt) < ($1.1.settledAt ?? $1.1.sentAt) }) else { return nil }
        let at = last.settledAt ?? last.sentAt
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(at) ? "HH:mm" : "MMM d HH:mm"
        let when = clock.string(from: at)
        let inFlight = ["waiting", "sending"].contains(last.phase)
        let summary: String
        if last.reply != nil { summary = "last answered \(when)" }
        else if inFlight, last.id == row.operationID { summary = "last message \(when), reply still coming" }
        else if inFlight { summary = "last message \(when), no reply came" }
        else {
            var detail: String?
            if last.id == row.operationID {
                if case .object(let receipt)? = row.receipt, case .string(let text)? = receipt["detail"] { detail = text }
                // A sentence, not a word like "delivering" or "interrupted".
                if let state = row.deliveryState, state.contains(" ") { detail = state }
            }
            let status = last.status == "unknown" ? last.phase : last.status
            summary = "last send \(status.replacingOccurrences(of: "_", with: " ")) \(when)"
                + (detail.map { " — " + String($0.prefix(160)) } ?? "")
        }
        return (summary, all.count)
    }
}
