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
    /// Checked approval storage settles saved decisions, including queued-send races; unavailable authority leaves exchanges untouched.
    func reconcileDeniedApprovals(_ rows: inout [AgentConversationRecord]) throws -> Bool {
        // The receipt owns approval waiting even if the record left attention through another path.
        let held = rows.indices.filter {
            guard case .object(let receipt)? = rows[$0].receipt else { return false }
            return receipt["approvalId"] != nil && AgentConversationRecord.approvalWaits(receipt["status"]?.stringValue ?? "")
        }
        // Ledger entries retain their own cards after the record advances.
        let ledgerHeld = rows.indices.filter { rows[$0].exchanges?.contains { $0.approvalId != nil && AgentConversationRecord.approvalWaits(
            $0.status) } == true }
        guard !held.isEmpty || !ledgerHeld.isEmpty else { return false }
        let decisions = try SwiftNativeApprovalInbox.loadApprovalRowsChecked(
            at: fileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workflows/approvals/requests.json"))
        var changed = false
        func decided(_ card: String) -> String? {
            guard let decision = decisions.first(where: { if case .object(let value) = $0 { value["id"] == .string(card) } else { false } }),
                  case .object(let approval) = decision, approval["status"] == .string("resolved"),
                  case .string(let status)? = approval["decision"], ["denied", "canceled"].contains(status) else { return nil }
            return status
        }
        for i in ledgerHeld {
            guard var history = rows[i].exchanges else { continue }
            for index in history.indices where history[index].approvalId != nil && AgentConversationRecord.approvalWaits(history[index].status)
                && history[index].id != rows[i].operationID {
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
            // Preserve the denial’s own time so it cannot hide newer replies.
            try Self.absorbExchange(into: &rows[i], file: fileURL)
            changed = true
        }
        return changed
    }

    func select(_ rows: [AgentConversationRecord], scope: String, agent: String, label: String?) throws -> AgentConversationRecord? {
        let matches = rows.filter { $0.scopeSessionID == scope && $0.agent == agent }
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
        for row in rows {
            guard row.operationStartedAt != nil else {
                throw Failure(message: """
                    Conversation \(row.id) has no operation start time. Repair its retained evidence in \(fileURL.path); existing bytes were \
                    preserved.
                    """)
            }
            try AgentConversationExchange.validate(row.exchanges, file: fileURL)
        }
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let life = try DataRootLife.current(in: root)
        for i in rows.indices {
            for j in rows[i].queued?.indices ?? 0..<0 where DataRootLife.life(of: rows[i].queued?[j].lifeID) != life {
                rows[i].queued?[j].held = DataRootLife.stoppedReason
                rows[i].queued?[j].waitingForMac = nil
                if rows[i].queueReservation == rows[i].queued?[j].id { rows[i].queueReservation = nil }
            }
            for j in rows[i].exchanges?.indices ?? 0..<0 where ["held", "delivering"].contains(rows[i].exchanges?[j].status ?? "")
                && DataRootLife.life(of: rows[i].exchanges?[j].lifeID) != life {
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
        return try reconcilingExpiredReplies(rows, peers: try AgentPeerStore(dataRoot: root).list())
    }

    func reconcilingExpiredReplies(_ records: [AgentConversationRecord], peers: [AgentPeerContact]) throws -> [AgentConversationRecord] {
        var rows = records
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let requests = GrokRequestStore(dataRoot: root)
        for i in rows.indices where ["sending", "waiting", "attention"].contains(rows[i].phase) {
            // Retain the previous receipt until dispatch settles.
            var receipt = rows[i].phase == "sending" ? .object([:]) : rows[i].receipt ?? .object([:])
            if peers.contains(where: { "peer:" + $0.id == rows[i].agent && $0.transport == .grokBot }),
               case .object(let fields) = receipt, fields["reply_deadline"] == nil,
               let id = rows[i].exchanges?.first(where: { $0.id == rows[i].operationID }).map({ GrokBotRoute.messageID(for: $0) }),
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
            for item in old.queued ?? [] where rows[index].queued?.contains(where: { $0.id == item.id }) != true {
                let promoted = old.queueReservation == item.id && rows[index].operationID == item.id && rows[index].phase == "sending"
                settle(item.id, key: "deliver", accepted: promoted, reason: .cancelled)
                if !promoted {
                    for key in ["accept", "answer"] { settle(item.id, key: key, accepted: false, reason: .cancelled) }
                }
            }
        }
        for row in rows { try AgentConversationExchange.validate(row.exchanges, file: fileURL) }
        // Pruned ledger evidence stays on the record until its terminal state reaches its transcript row.
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
