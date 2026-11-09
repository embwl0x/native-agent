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
import Transcripts
// Blueprint: | `AgentConversationStore.swift` | Retained conversation identity, send evidence, queue reservations and checked mutations. |



public struct AgentConversationStore: Sendable {
    public let fileURL: URL
    public init(dataRoot: URL) { fileURL = dataRoot.appendingPathComponent("agents/conversations.json") }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var effects: ToolFailureError.Effects = .none
        package init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public func records() throws -> [AgentConversationRecord] {
        try locked {
            var rows = try load()
            if try reconcileDeniedApprovals(&rows) { try save(rows) }
            return rows
        }
    }

    /// Unlocked glance reads must not block; a file caught mid-write remains a decode failure.
    public func recordsUnlocked() throws -> [AgentConversationRecord] { try load() }

    public func find(scopeSessionID: String, agent: String, label: String?, in snapshot: [AgentConversationRecord]? = nil) throws -> AgentConversationRecord? {
        let rows = try snapshot ?? records()
        return try select(rows, scope: scopeSessionID, agent: agent, label: label)
            ?? (label == nil && Self.ownThread(scope: scopeSessionID, agent: agent) != nil ? nil : Self.continuing(rows, agent: agent, label: label))
    }

    /// Resolve conversation identities through their owners, including contacts whose send record has no chat/messages file of its own.
    public func containsConversation(_ id: String) throws -> Bool {
        try resolveConversation(id) != nil
    }

    package enum ConversationIdentity: Sendable {
        case session([String: JSONValue])
        case agent(AgentConversationRecord)
    }

    /// Page reads and Desk waits share the exact identity resolver used for agent.read's record, protocol and contact-session ids.
    package func resolveConversation(_ id: String, scope: String? = nil, matchingTitle: Bool = false) throws -> ConversationIdentity? {
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let session = Result { try SessionConversation.checkedRow(id, dataRoot: root) }
        if case .success(let row?) = session { return .session(row) }
        if let row = Self.conversation(id, scope: scope, in: try records()) { return .agent(row) }
        // A readable contact can establish its own identity even if the session index is unavailable; absence in both owners needs both reads.
        _ = try session.get()
        // Exact ids from either owner outrank a session whose title happens to be that id.
        if matchingTitle, let row = try SessionConversation.checkedRow(id, dataRoot: root, matchingTitle: true) { return .session(row) }
        return nil
    }

    /// The same exact IDs select an agent.read conversation and admit a Desk wait. Labels remain scoped to their named contact.
    static func conversation(_ id: String, scope: String?, in rows: [AgentConversationRecord]) -> AgentConversationRecord? {
        if let exact = rows.first(where: { $0.id == id }) { return exact }
        return rows.filter { row in
            row.conversationID == id || (row.agent.hasPrefix("peer:")
                && ContactThread.session(owner: String(row.agent.dropFirst(5)), conversation: row.conversationID) == id)
        }.max { ($0.scopeSessionID == scope ? 1 : 0, $0.updatedAt) < ($1.scopeSessionID == scope ? 1 : 0, $1.updatedAt) }
    }

    /// In the session of a conversation the contact opened by calling in (its own, or one caller's), that conversation: an unnamed message to the
    /// contact there goes back to that caller there, never to another caller or another door. Nil in any other chat.
    static func ownThread(scope: String, agent: String) -> String? {
        guard agent.hasPrefix("peer:") else { return nil }
        let owner = String(agent.dropFirst(5)), prefix = ContactThread.prefix(owner: owner)
        guard scope.hasPrefix(prefix), let held = ContactCaller.held(String(scope.dropFirst(prefix.count)), peer: owner) else { return nil }
        return ContactThread.session(owner: owner, conversation: held) == scope ? held : nil
    }

    /// A held conversation's name, the same for every send in it: a caller's names the contact and when that caller opened; the contact's own
    /// conversation carries the contact's name.
    static func heldName(_ conversation: String, agent: String, contact: String) -> String {
        ContactCaller(conversation: conversation, peer: String(agent.dropFirst(5))).map { $0.name(contact: contact) } ?? contact
    }

    static func continuing(_ rows: [AgentConversationRecord], agent: String, label: String?) -> AgentConversationRecord? {
        rows.filter { row in
            guard row.agent == agent else { return false }
            if let label { return row.label.caseInsensitiveCompare(label) == .orderedSame }
            // A thread the contact opened by calling in belongs to the chat it called in; another chat continues it only by name.
            let held = agent.hasPrefix("peer:") && ContactCaller.held(row.conversationID, peer: String(agent.dropFirst(5))) != nil
            return !held && (row.label == "Main" || row.selected)
        }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Reserve before dispatch to prevent concurrent sends against one bookmark. Bind protocol identity separately from operation identity; crashes preserve
    /// uncertainty, never replay authority.
    public func begin(scopeSessionID: String, agent: String, name: String, label: String?, record: String? = nil,
                      fresh: Bool, sourceSurface: String, fingerprint: String?,
                      replyRoute: [String: String]?, message: String? = nil,
                      personInitiated: Bool = false,
                      supersedeWaiting: Bool = false, expectsReply: Bool? = nil,
                      reservation: String? = nil, messageID: String? = nil) throws -> AgentConversationRecord {
        if let messageID, messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolFailureError("message_id must be a non-empty protocol message string.",
                argumentPath: "message_id", effects: .none)
        }
        // Every record names its contact; replies are attributed by it (BridgeLane.bridgeSurfaceName).
        guard !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Name the contact this conversation is with. Nothing was sent.")
        }
        guard !scopeSessionID.isEmpty, scopeSessionID.utf8.count <= 256,
              label == nil || (label!.count <= 120 && !label!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw Failure(message: "Choose a short conversation name.")
        }
        return try locked {
            var rows = try load()
            if try reconcileDeniedApprovals(&rows) { try save(rows) }
            // Continue the exact record resolved by the caller.
            let ownHeld = label == nil ? Self.ownThread(scope: scopeSessionID, agent: agent) : nil
            let old = try record.flatMap { id in rows.first { $0.id == id && $0.agent == agent } }
                ?? select(rows, scope: scopeSessionID, agent: agent, label: label)
                ?? (fresh || ownHeld != nil ? nil : Self.continuing(rows, agent: agent, label: label))
            // An accepted ask its peer never answered (Grok Bot) may be superseded; an unsettled send never is.
            if !fresh, let old, old.phase == "sending" || (old.phase == "waiting" && !supersedeWaiting) {
                throw Failure(
                    message: "This conversation is still waiting for its previous message. Open it to see the current state; do not send that message again.")
            }
            // A queued message taken to go next keeps its place. Its own send begins only while it is still reserved and still queued (not withdrawn).
            if !fresh, let old, let held = old.queueReservation, held != reservation {
                throw Failure(message: "A queued message on this conversation is going first; send again to queue behind it.")
            }
            if let reservation, fresh || old?.queueReservation != reservation
                || old?.queued?.contains(where: { $0.id == reservation }) != true {
                throw Failure(message: "That queued message was withdrawn before it went; nothing was sent.")
            }
            if !fresh, let old, old.peerRouteFingerprint != fingerprint {
                throw Failure(
                    message: "This contact's connection changed. Start a separate conversation explicitly; the existing conversation has been preserved.")
            }
            if fresh, label != nil, old != nil {
                throw Failure(message: "That conversation name is already in use. Choose a different name for a separate conversation.")
            }
            var row: AgentConversationRecord
            if !fresh, let old {
                row = old
                // Continuing from another chat transfers the thread’s scope to that chat.
                row.scopeSessionID = scopeSessionID
            } else {
                guard rows.count < 512 else { throw Failure(message: "The saved conversation limit has been reached.") }
                let id = UUID().uuidString.lowercased()
                row = AgentConversationRecord(id: id, scopeSessionID: scopeSessionID, agent: agent, name: name,
                    label: label ?? (fresh ? "Conversation " + String(id.prefix(8))
                        : ownHeld.map { Self.heldName($0, agent: agent, contact: name) } ?? "Main"),
                    phase: "ready", operationID: id, updatedAt: Date(), sourceSurface: sourceSurface)
                // Opened in the contact's own thread, it lives on the door that thread came through.
                if !fresh, let ownHeld { row.conversationID = ownHeld }
            }
            try Self.absorbExchange(into: &row, file: fileURL)
            // Queued promotion retains the original experience.
            row.operationID = reservation ?? UUID().uuidString.lowercased()
            row.lifeID = try DataRootLife.current(in: fileURL.deletingLastPathComponent().deletingLastPathComponent())
            row.phase = "sending"
            row.updatedAt = Date()
            row.operationStartedAt = row.updatedAt
            let resumed = reservation.flatMap { id in row.exchanges?.first { $0.id == id && $0.status == "held" } }
            var exchange = resumed ?? .started(operationID: row.operationID, at: row.updatedAt, message: message, byPerson: personInitiated)
            exchange.messageID = messageID
            exchange.phase = "sending"; exchange.status = "sending"; exchange.settledAt = nil
            row.exchanges = try AgentConversationExchange.bounded((row.exchanges ?? []).filter { $0.id != row.operationID } + [exchange], file: fileURL)
            if let latest = row.exchanges?.indices.last { row.exchanges?[latest].lifeID = row.lifeID }
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

    /// If the reply settled meanwhile, leave the send to the caller instead of queuing it.
    public func enqueue(id: String, scopeSessionID: String, text: String, byPerson: Bool, arguments: [String: JSONValue]? = nil,
                        stillInFlight: (AgentConversationRecord) throws -> Bool) throws -> (AgentConversationRecord, AgentConversationQueued)? {
        guard !scopeSessionID.isEmpty, scopeSessionID.utf8.count <= 256 else {
            throw Failure(message: "The queued message needs its caller's conversation; nothing was queued.")
        }
        return try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), try stillInFlight(rows[i]) else { return nil }
            guard (rows[i].queued ?? []).count < 20 else {
                throw Failure(message: "Twenty messages are already queued on this conversation; nothing more was added.")
            }
            var item = AgentConversationQueued(id: UUID().uuidString.lowercased(), scopeSessionID: scopeSessionID,
                                               text: text, queuedAt: Date(),
                                               byPerson: byPerson ? true : nil, arguments: arguments)
            item.lifeID = try DataRootLife.current(in: fileURL.deletingLastPathComponent().deletingLastPathComponent())
            rows[i].queued = (rows[i].queued ?? []) + [item]
            rows[i].updatedAt = Date()
            try save(rows)
            return (rows[i], item)
        }
    }

    /// Reserve only the oldest queued send after settlement, keeping the thread occupied until begin or release.
    public func takeQueued(id: String, item: String, ready: (AgentConversationRecord) throws -> Bool) throws -> AgentConversationQueued? {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].queueReservation == nil, try ready(rows[i]),
                  let head = rows[i].queued?.first(where: { $0.held == nil || $0.waitingForMac == true }),
                  head.held == nil, head.id == item else { return nil }
            // Keep a reservation visible in the queue until its send begins.
            rows[i].queueReservation = item
            try save(rows)
            return head
        }
    }

    /// Releasing an unused reservation proves its send never began.
    public func releaseReservation(id: String, item: String) throws -> Bool {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].queueReservation == item else { return false }
            rows[i].queueReservation = nil
            try save(rows)
            return true
        }
    }

    /// A refusal before begin settles this queued send; withdrawal or a begun send cannot be reinserted.
    public func refuseQueued(id: String, item: AgentConversationQueued, reason: String, reserved: Bool = false) throws {
        let saved: (row: AgentConversationRecord, item: AgentConversationQueued)? = try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }) else {
                throw Failure(message: "The refused message's conversation is missing; its settlement could not be saved.")
            }
            guard !reserved || rows[i].queueReservation == item.id,
                  var queued = rows[i].queued,
                  let j = queued.firstIndex(where: { $0.id == item.id }) else { return nil }
            queued[j].held = reason
            queued[j].waitingForMac = nil
            rows[i].queued = queued
            if rows[i].queueReservation == item.id { rows[i].queueReservation = nil }
            if rows[i].operationID == item.id, rows[i].sendEvidence["reason"] == .string("mac_busy") {
                rows[i].receipt = .object(["status": .string("not_sent"), "sent": .bool(false), "terminal": .bool(true),
                    "detail": .string(reason)])
            }
            rows[i].updatedAt = Date()
            try save(rows)
            return (rows[i], queued[j])
        }
        if let saved, saved.item.byPerson != true {
            guard let scope = saved.item.scopeSessionID, !scope.isEmpty else {
                throw Failure(message: "Message \(saved.item.id) was not sent, but its queued caller is missing; "
                    + "its refusal notice could not be returned.")
            }
            Self.returnNews(saved.row, scope: scope, once: "not-sent:" + saved.item.id,
                words: saved.row.name + ": " + TurnSecretRedactor.redactText(reason), peers: [saved.row.agent],
                dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    /// The desktop route calls only before emitting Return. Full text stays in this owner's existing queue, under the same send id and original age.
    public func holdForMac(id: String, operation: String, text: String, conversation: String?, detail: String) throws {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id && $0.operationID == operation }),
                  rows[i].phase == "sending" || AgentConversationSession.backgroundSend(rows[i]),
                  let started = rows[i].exchanges?.first(where: { $0.id == operation })?.sentAt else {
                throw Failure(message: "The conversation moved on; no waiting message was saved.")
            }
            let args: [String: JSONValue] = ["expects_reply": .bool(rows[i].awaitsReply)]
            // Exact desktop requests must retain their requested chat title.
            if let conversation { rows[i].conversationID = conversation }
            var item = AgentConversationQueued(id: operation, scopeSessionID: rows[i].scopeSessionID, text: text,
                queuedAt: started,
                byPerson: rows[i].personInitiated, arguments: args,
                held: detail + " Waiting for the Mac to be free; it will go then.")
            item.lifeID = rows[i].lifeID
            item.waitingForMac = true
            rows[i].queued = [item] + (rows[i].queued ?? []).filter { $0.id != operation }
            try save(rows)
        }
    }

    /// Late replies settle their own exchange, never the current send. Only committed reply storage can settle its repair debt.
    public func settleExchange(id: String, exchange: String, reply: String?, receipt: JSONValue? = nil,
                               firstActivity: Date? = nil, stopDetail: String? = nil) throws {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }), var history = rows[i].exchanges,
                  let j = history.firstIndex(where: { $0.id == exchange }) else {
                throw Failure(message: "This conversation exchange is no longer retained; its reply was not saved.")
            }
            let before = rows[i]
            if history[j].firstActivityAt == nil { history[j].firstActivityAt = firstActivity }
            if rows[i].operationID == exchange, let receipt {
                rows[i].receipt = Self.cacheReceipt(receipt)
                rows[i].phase = reply == nil ? "attention" : "ready"
                if let stopDetail {
                    rows[i].stop = AgentConversationStop(state: "released", operationID: exchange, at: Date(), detail: stopDetail)
                    rows[i].phase = "ready"
                }
                rows[i].automaticRead = false; rows[i].nextReadAt = nil
                rows[i].exchanges = history
                try Self.absorbExchange(into: &rows[i], file: fileURL)
                rows[i].updatedAt = Date()
            } else {
                if history[j].reply != nil { return }
                if let reply {
                    let text = AgentConversationExchange.clipped(reply, limit: AgentConversationExchange.textLimit)
                    history[j].reply = text.text; history[j].replyTruncated = text.truncated
                }
                if case .object(let fields)? = receipt {
                    if case .string(let entryID)? = fields["entry_id"] { history[j].resultID = UUID(uuidString: entryID) }
                    if case .string(let partial)? = fields["partial_reply"] {
                        history[j].partialReply = AgentConversationExchange.clipped(partial, limit: AgentConversationExchange.textLimit).text
                    }
                    if case .string(let status)? = fields["status"] { history[j].status = status }
                } else { history[j].status = "answered" }
                history[j].phase = stopDetail != nil || reply != nil ? "ready" : "attention"
                history[j].settledAt = Date()
                rows[i].exchanges = try AgentConversationExchange.bounded(history, file: fileURL)
            }
            try save(rows)
            // The route read attests the reply’s provenance.
            noteReplies(was: before, now: rows[i], from: rows[i].agent,
                        answer: reply.map { (exchange, $0) }, retained: receipt.flatMap {
                            if case .object(let fields) = $0, fields["reply_location"] != nil { exchange } else { nil }
                        })
        }
        RepairOwed.settle(fileURL.deletingLastPathComponent().deletingLastPathComponent(),
            operation: "agent.reply.settlement:" + exchange, evidence: .init(source: fileURL.path, id: exchange))
    }

    /// Contacts with direct sessions or no saved recipient cannot settle records here; archive dropped records whole before removal.
    @discardableResult public func dropUnsettleable(dot: Set<String>, saved: Set<String>) throws -> Int {
        try locked {
            let rows = try load()
            let dropped = rows.filter { row in
                if dot.contains(row.agent) { return true }
                guard row.agent.hasPrefix("peer:"), !saved.contains(row.agent) else { return false }
                return ["sending", "waiting"].contains(row.phase) || !(row.queued ?? []).isEmpty || row.queueReservation != nil
            }
            guard !dropped.isEmpty else { return 0 }
            let archive = fileURL.deletingLastPathComponent().appendingPathComponent("conversations-dropped.jsonl")
            var lines = Data()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for row in dropped { lines += try encoder.encode(row) + Data([0x0A]) }
            try SwiftNativePersistenceCore.appendOwnedBytes(lines, to: archive, durable: true)
            let ids = Set(dropped.map(\.id))
            try save(rows.filter { !ids.contains($0.id) })
            recordExperiences(dropped, dropped: true)
            return dropped.count
        }
    }

    @discardableResult public func clearQueued(id: String) throws -> Int {
        try locked {
            var rows = try load()
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return 0 }
            let count = rows[i].queued?.count ?? 0
            // A reserved message is withdrawn too: its sender's begin then refuses.
            let reserved = rows[i].queueReservation != nil
            if rows[i].queued?.contains(where: { $0.id == rows[i].operationID }) == true,
               rows[i].sendEvidence["reason"] == .string("mac_busy") {
                rows[i].receipt = .object(["status": .string("cancelled"), "sent": .bool(false), "terminal": .bool(true),
                    "detail": .string("The waiting message was withdrawn. Nothing was sent.")])
                rows[i].stop = .init(state: "stopped", operationID: rows[i].operationID, at: Date(),
                    detail: "The waiting message was withdrawn. Nothing was sent.")
                try Self.absorbExchange(into: &rows[i], file: fileURL)
            }
            rows[i].queued = nil
            rows[i].queueReservation = nil
            if count > 0 || reserved { rows[i].updatedAt = Date(); try save(rows) }
            return count
        }
    }

    /// `touch: false` (a read) moves updatedAt only when the phase or the newest reply changed, so opening a conversation never reads as news.
    @discardableResult public func update(id: String, operationID: String, touch: Bool = true,
        edit: (inout AgentConversationRecord) throws -> Void) throws -> AgentConversationRecord {
        try locked {
            var rows = try load()
            let original = rows
            guard let i = rows.firstIndex(where: { $0.id == id && $0.operationID == operationID }) else {
                throw Failure(message: "This conversation has moved on; the older result was not applied.")
            }
            let identity = rows[i]
            try edit(&rows[i])
            guard rows[i].id == identity.id, rows[i].agent == identity.agent,
                  rows[i].scopeSessionID == identity.scopeSessionID,
                  rows[i].operationID == operationID else { throw Failure(message: "Conversation identity cannot change.") }
            try Self.absorbExchange(into: &rows[i], file: fileURL)
            if touch || rows[i].phase != identity.phase || rows[i].exchanges?.last?.reply != identity.exchanges?.last?.reply {
                rows[i].updatedAt = Date()
            }
            if rows[i].selected {
                for j in rows.indices where j != i && rows[j].scopeSessionID == rows[i].scopeSessionID && rows[j].agent == rows[i].agent {
                    rows[j].selected = false
                }
            }
            if rows == original { return rows[i] }
            try save(rows)
            // Only the route owner can attest the reply.
            noteReplies(was: identity, now: rows[i], from: rows[i].agent)
            return rows[i]
        }
    }

    // Routes include chat and workspace; reconnects verify program paths without making them route identity.
    public static func routeFingerprint(_ peer: AgentPeerContact) -> String {
        fingerprint(peer, program: "", full: true)
    }

    /// A saved route must identify the complete current route.
    public static func sameRoute(_ saved: String?, _ peer: AgentPeerContact?) -> Bool {
        guard let peer else { return saved == nil }
        return saved == routeFingerprint(peer)
    }

    private static func fingerprint(_ peer: AgentPeerContact, program: String, full: Bool = false) -> String {
        let fields = [peer.transport.rawValue, peer.endpoint.absoluteString, peer.acpWorkingDirectory ?? "", program]
            + (full ? [peer.conversationLabel ?? "", peer.hostWorkspace ?? ""] : [])
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension AgentConversationStore {
    /// Conversation words come from the contact’s own session; the newest send record alone cannot summarize both sides.
    public static func lastExchanges(peers: [AgentPeerContact], records: [AgentConversationRecord],
                                     dataRoot: URL) -> [String: (summary: String, count: Int, replyState: JSONValue?)] {
        var found: [String: (summary: String, count: Int, replyState: JSONValue?)] = [:]
        let identity = AgentContactIdentity(contacts: peers)
        for peer in peers {
            let lines: [ContactThread.Line]
            do { lines = try ContactThread.mergedLines(dataRoot: dataRoot, owner: peer.id, identity: identity) }
            catch {
                found[peer.id] = ("History unavailable: \(error.localizedDescription)", 0, nil)
                continue
            }
            guard let last = lines.last else { continue }
            let row = records.filter { $0.agent == "peer:" + peer.id }.max { $0.updatedAt < $1.updatedAt }
            let receipt = ChatGPTDotIPCTransport.owns(peer)
                ? AgentConversationView.dotReply(.object([:]), sentAt: last.mine ? last.at : nil) : row?.phase == "sending" ? nil : row?.receipt
            // Its exchanges are the times it spoke, not every line both sides wrote.
            found[peer.id] = (summary(last, answering: lines.dropLast().contains(where: \.mine), row: row, receipt: receipt),
                              lines.filter { !$0.mine }.count,
                              last.mine ? receipt.flatMap { if case .object(let fields) = $0 { fields["reply_state"] } else { nil } } : nil)
        }
        return found
    }

    private static func summary(_ last: ContactThread.Line, answering: Bool, row: AgentConversationRecord?, receipt: JSONValue?) -> String {
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(last.at) ? "HH:mm" : "MMM d HH:mm"
        let when = clock.string(from: last.at)
        if !last.mine { return answering ? "last answered \(when)" : "last heard from them \(when)" }
        if case .object(let fields)? = receipt, fields["status"] == .string("waiting") { return "last message \(when), reply still coming" }
        guard let row, let current = row.exchanges?.last(where: { $0.id == row.operationID }) else {
            return "last message \(when), no reply came"
        }
        if ["waiting", "sending"].contains(current.phase) { return "last message \(when), reply still coming" }
        var detail: String?
        if case .object(let receipt)? = row.receipt, case .string(let text)? = receipt["detail"] { detail = text }
        // Use a sentence so the state is actionable rather than an isolated status word.
        if let state = row.deliveryState, state.contains(" ") { detail = state }
        let status = current.status == "unknown" ? current.phase : current.status
        return "last send \(status.replacingOccurrences(of: "_", with: " ")) \(when)"
            + (detail.map { " — " + String($0.prefix(160)) } ?? "")
    }
}
