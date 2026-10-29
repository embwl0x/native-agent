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
// Blueprint: | `AgentConversationPersistence.swift` | Checked conversation serialization and projection publication under the existing file lock |

extension AgentConversationStore {
    /// Heal decisions already saved before this process saw them, including a denial racing a queued follow-up's begin. Approval storage is checked; unavailable authority leaves the exchange untouched.
    func reconcileDeniedApprovals(_ rows: inout [AgentConversationRecord]) throws -> Bool {
        // The receipt alone says the send waits on a card; a record that left "attention" another way (a stop, a release) still settles its denial.
        let held = rows.indices.filter {
            guard case .object(let receipt)? = rows[$0].receipt else { return false }
            return receipt["approvalId"] != nil && AgentConversationRecord.approvalWaits(receipt["status"]?.stringValue ?? "")
        }
        // Older sends in the ledger wait on their own cards; a decision made after the record moved on settles them too.
        let ledgerHeld = rows.indices.filter { rows[$0].exchanges?.contains { $0.approvalId != nil && AgentConversationRecord.approvalWaits($0.status) } == true }
        guard !held.isEmpty || !ledgerHeld.isEmpty,
              let decisions = try? SwiftNativeApprovalInbox.loadApprovalRowsChecked(
                at: fileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workflows/approvals/requests.json")) else { return false }
        var changed = false
        func decided(_ card: String) -> String? {
            guard let decision = decisions.first(where: { if case .object(let value) = $0 { value["id"] == .string(card) } else { false } }),
                  case .object(let approval) = decision, approval["status"] == .string("resolved"),
                  case .string(let status)? = approval["decision"], ["denied", "canceled"].contains(status) else { return nil }
            return status
        }
        for i in ledgerHeld {
            guard var history = rows[i].exchanges else { continue }
            for index in history.indices where history[index].approvalId != nil && AgentConversationRecord.approvalWaits(history[index].status) && history[index].id != rows[i].operationID {
                guard let status = decided(history[index].approvalId!) else { continue }
                history[index].status = status; history[index].phase = "ready"
                if history[index].settledAt == nil { history[index].settledAt = Date() }
                changed = true
            }
            rows[i].exchanges = try AgentConversationExchange.bounded(history, file: fileURL)
        }
        for i in held {
            guard case .object(let receipt)? = rows[i].receipt,
                  let decision = decisions.first(where: { if case .object(let value) = $0 { value["id"] == receipt["approvalId"] } else { false } }),
                  case .object(let approval) = decision, approval["status"] == .string("resolved"),
                  case .string(let status)? = approval["decision"], ["denied", "canceled"].contains(status) else { continue }
            let outcome: ToolNotRunStatus = status == "denied" ? .personDenied : .approvalCanceled
            rows[i].receipt = .object(["status": .string(status), "sent": .bool(false), "completed": .bool(false),
                "approvalId": receipt["approvalId"]!, "detail": .string(outcome.sentence())])
            rows[i].phase = "ready"; rows[i].automaticRead = false; rows[i].nextReadAt = nil; rows[i].deliveryState = nil
            // Keep its own time: settling an old denial must not make it the contact's newest send (it hid newer replies behind "denied").
            try Self.absorbExchange(into: &rows[i], file: fileURL)
            changed = true
        }
        return changed
    }

    func select(_ rows: [AgentConversationRecord], scope: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        let matches = rows.filter { $0.scopeSessionID == scope && $0.agent == agent }
        // Without a name, use the selected thread or latest activity; ambiguous names require an id.
        if let label {
            let named = matches.filter { $0.id == label || $0.label.caseInsensitiveCompare(label) == .orderedSame }
            guard named.count <= 1 else {
                throw Failure(message: "Choose a conversation: more than one is named “\(label)”; name it by id: "
                    + named.map(\.id).joined(separator: ", "))
            }
            return named.first
        }
        return matches.first(where: { $0.selected }) ?? matches.max { $0.updatedAt < $1.updatedAt }
    }

    func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(fileURL, work)
    }
    func load() throws -> [AgentConversationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 50 * 1024 * 1024 else { throw Failure(message: "Saved conversations are too large to read safely.") }
        var rows = try JSONDecoder().decode([AgentConversationRecord].self, from: data)
        guard rows.count <= 512, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.operationID) != nil && !$0.scopeSessionID.isEmpty }) else {
            throw Failure(message: "Saved conversations are unavailable; existing records were preserved.")
        }
        for row in rows { try AgentConversationExchange.validate(row.exchanges, file: fileURL) }
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let life = try DataRootLife.current(in: root)
        for i in rows.indices {
            for j in rows[i].queued?.indices ?? 0..<0 where DataRootLife.life(of: rows[i].queued?[j].lifeID) != life {
                rows[i].queued?[j].held = DataRootLife.stoppedReason
                if rows[i].queueReservation == rows[i].queued?[j].id { rows[i].queueReservation = nil }
            }
            for j in rows[i].exchanges?.indices ?? 0..<0 where ["held", "delivering"].contains(rows[i].exchanges?[j].status ?? "") && DataRootLife.life(of: rows[i].exchanges?[j].lifeID) != life {
                rows[i].exchanges?[j].phase = "stopped"
                rows[i].exchanges?[j].status = DataRootLife.stoppedReason
            }
            guard DataRootLife.life(of: rows[i].lifeID) != life,
                  ["sending", "waiting"].contains(rows[i].phase) || rows[i].automaticRead || rows[i].deliveryState == "delivering" else { continue }
            rows[i].phase = "stopped"
            rows[i].stop = .init(state: "stopped", operationID: rows[i].operationID,
                                 at: rows[i].updatedAt, detail: DataRootLife.stoppedReason)
            rows[i].automaticRead = false
            rows[i].notice = nil
            rows[i].nextReadAt = nil
            rows[i].deliveryState = "stopped"
            var receipt: [String: JSONValue] = rows[i].receipt.flatMap { if case .object(let fields) = $0 { fields } else { nil } } ?? [:]
            receipt["status"] = .string("stopped")
            receipt["reason"] = .string(DataRootLife.stoppedReason)
            rows[i].receipt = .object(receipt)
        }
        guard let peers = try? AgentPeerStore(dataRoot: root).list() else { return rows }
        for index in rows.indices where AgentConversationDelivery.inbox(agent: rows[index].agent,
            bridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root)) != nil {
            let owners = peers.filter { ($0.handles ?? []).contains(rows[index].agent) }
            if owners.count == 1, let who = owners.first {
                rows[index].agent = "peer:" + who.id
                rows[index].name = who.name
                rows[index].peerRouteFingerprint = Self.routeFingerprint(who)
                rows[index].readInput?["agent"] = .string("peer:" + who.id)
            } else {
                rows[index].phase = "attention"
                let lane = rows[index].agent
                rows[index].deliveryState = "\(lane) had no reader on this Mac; this saved message is owed to no one. Its record is preserved."
            }
        }
        for index in rows.indices where rows[index].phase == "waiting" && AgentConversationDelivery.claudeInbox(rows[index]) {
            guard case .object(var receipt)? = rows[index].receipt, receipt["read"] != .bool(true),
                  case .string(let path)? = receipt["filePath"], case .string(let message)? = rows[index].readInput?["message_id"],
                  let peer = peers.first(where: { "peer:" + $0.id == rows[index].agent }) else { continue }
            guard let door = (peer.handles ?? []).compactMap({ AgentConversationDelivery.door(for: $0, dataRoot: root) })
                .first(where: { $0.inbox.path == path }) else { continue }
            receipt["remedy"] = door.remedy()
            if DelegationStatusProjector.requestRecords(inbox: door.inbox, ids: [message])[message]?["read"] == "true" { receipt["read"] = .bool(true) }
            AgentConversationSession.absorb(.object(receipt), into: &rows[index])
            try Self.absorbExchange(into: &rows[index], file: fileURL)
        }
        // Derive old inconsistent snapshots from their receipt without a migration write. History and home see the same failed send now.
        for i in rows.indices where rows[i].phase != "sending" && rows[i].sendFailed {
            var row = rows[i]
            row.phase = "attention"
            let status = row.sendStatus, operation = row.operationID, updatedAt = row.updatedAt
            if let j = row.exchanges?.firstIndex(where: { $0.id == operation }) {
                row.exchanges?[j].phase = "attention"
                row.exchanges?[j].status = status
                if row.exchanges?[j].settledAt == nil { row.exchanges?[j].settledAt = updatedAt }
            }
            rows[i] = row
        }
        return try reconcilingExpiredReplies(rows)
    }

    func reconcilingExpiredReplies(_ records: [AgentConversationRecord]) throws -> [AgentConversationRecord] {
        var rows = records
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let requests = GrokRequestStore(dataRoot: root)
        for i in rows.indices where ["sending", "waiting", "attention"].contains(rows[i].phase) {
            // A send retains the previous receipt until dispatch settles.
            var receipt = rows[i].phase == "sending" ? .object([:]) : rows[i].receipt ?? .object([:])
            if rows[i].agent.hasPrefix("peer:"), case .object(let fields) = receipt, fields["reply_deadline"] == nil,
               case .string(let id) = rows[i].readInput?["message_id"] ?? .string(rows[i].operationID),
               FileManager.default.fileExists(atPath: requests.root.appendingPathComponent(id + ".json").path) {
                receipt = GrokBotRoute.projection(try requests.read(id, peer: String(rows[i].agent.dropFirst(5))))
            }
            receipt = AgentConversationView.expiringReply(receipt)
            if case .object(let fields) = receipt, fields["reply_state"] == .string("no_reply_expired") {
                AgentConversationSession.absorb(receipt, into: &rows[i])
                try Self.absorbExchange(into: &rows[i], file: fileURL)
            }
        }
        return rows
    }
    func save(_ rows: [AgentConversationRecord]) throws {
        let previous = try load()
        var rows = rows
        for index in rows.indices {
            guard let old = previous.first(where: { $0.id == rows[index].id }) else { continue }
            func settle(_ id: String, key: String, accepted: Bool, reason: ObligationPhase.LetGo) {
                var obligation = Experience.Obligation(to: "conversation:" + old.id)
                obligation.phase = accepted ? .accepted : .letGo
                if accepted { obligation.evidence = .init(source: "agents/conversations", id: old.id) }
                else { obligation.reason = reason }
                var settled = rows[index].settledObligations ?? [:]
                settled[id, default: [:]][key] = obligation
                rows[index].settledObligations = settled
            }
            if old.operationID != rows[index].operationID {
                settle(old.operationID, key: "answer", accepted: false, reason: .abandoned)
            }
            for item in old.queued ?? [] where rows[index].queued?.contains(where: { $0.id == item.id }) != true {
                let promoted = old.queueReservation == item.id && old.operationID != rows[index].operationID
                settle(item.id, key: "deliver", accepted: promoted, reason: .cancelled)
                if !promoted {
                    for key in ["accept", "answer"] { settle(item.id, key: key, accepted: false, reason: .cancelled) }
                }
            }
        }
        for row in rows { try AgentConversationExchange.validate(row.exchanges, file: fileURL) }
        // A send the bounded ledger lets go keeps its evidence on the record, in this same write, until its last state is on its own transcript row.
        var released = false
        for index in rows.indices where rows[index].agent.hasPrefix("peer:") {
            guard let old = previous.first(where: { $0.id == rows[index].id }) else { continue }
            let kept = Set((rows[index].exchanges ?? []).map(\.id) + (rows[index].releasing ?? []).map(\.id))
            let letGo = (old.exchanges ?? []).filter { !kept.contains($0.id) }
            if !letGo.isEmpty { rows[index].releasing = (rows[index].releasing ?? []) + letGo; released = true }
        }
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let data = try JSONEncoder().encode(rows)
        guard data.count <= 50 * 1024 * 1024 else {
            throw Failure(message: "Saved conversations exceed their storage limit; existing records were preserved.")
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
        recordExperiences(rows)
        if rows.contains(where: { row in
            if row.phase == "attention" { return true }
            if case .object(let receipt)? = row.receipt { return receipt["reply_state"] == .string("no_reply_expired") }
            return false
        }) {
            Task.detached(priority: .utility) { await AgentContactHealth.shared.refresh(dataRoot: root) }
        }
        try? AgentConversationLiveStore(dataRoot: root).merge([], records: rows)
        AgentConversationRunning.shared.changed() // wakes queued follow-ups
        if released { Self.release(dataRoot: root) }
    }
}
