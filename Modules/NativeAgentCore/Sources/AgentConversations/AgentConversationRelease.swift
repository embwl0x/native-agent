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
import MacControl
// Blueprint: | `AgentConversationRelease.swift` | Conversation release and experience settlement; positive MacPersonInput away evidence and a permitted fresh driver unhold pre-Return desktop sends in the existing queue under the same drain claim; every open send closes from its row's exchange when superseded, all unsettled keys release on failure, and seen rows for removed contacts abandon their debts; pending drains remain under one claim |

extension AgentConversationStore {
    private static let releasingNow = OSAllocatedUnfairLock(initialState: (draining: false, pending: false))
    /// The last failure reported for each held send, so an unchanged one is said once.
    private static let releaseFailures = OSAllocatedUnfairLock(initialState: [String: String]())

    /// Each let-go send's last state goes onto its own row through the transcript owner (live or archived copy); only then does its evidence leave the record. Startup restores projections once before draining.
    package static func restoreProjections(dataRoot: URL) {
        let store = Self(dataRoot: dataRoot)
        do {
            try store.locked {
                let rows = try store.load()
                store.recordExperiences(rows)
                try? AgentConversationLiveStore(dataRoot: dataRoot).merge([], records: rows)
                let archive = store.fileURL.deletingLastPathComponent().appendingPathComponent("conversations-dropped.jsonl")
                if FileManager.default.fileExists(atPath: archive.path) {
                    let dropped = try Data(contentsOf: archive).split(separator: 10).map { try JSONDecoder().decode(AgentConversationRecord.self, from: Data($0)) }
                    store.recordExperiences(dropped.filter { old in !rows.contains { $0.id == old.id } }, dropped: true)
                }
            }
        } catch { ExperienceStore.record(dataRoot, "agent-conversations") { _ in throw error } }
        release(dataRoot: dataRoot)
    }

    static func release(dataRoot: URL) {
        // A call during a drain is never dropped: the drain takes one more snapshot before it goes idle.
        guard releasingNow.withLock({ state -> Bool in
            if state.draining { state.pending = true; return false }
            state = (true, false); return true
        }) else { return }
        Task.detached {
            repeat { await drainReleasing(dataRoot: dataRoot) }
            while releasingNow.withLock { state -> Bool in
                if state.pending { state.pending = false; return true }
                state.draining = false; return false
            }
        }
    }

    private static func drainReleasing(dataRoot: URL) async {
        let store = AgentConversationStore(dataRoot: dataRoot)
        // Positive presence evidence only. Startup and a presence/driver edge
        // enter this same drain claim; absence never releases a waiting send.
        if MacPersonInput.presence()?.here == false,
           let waiting = try? store.recordsUnlocked(),
           waiting.contains(where: { $0.queued?.contains(where: { $0.waitingForMac == true }) == true }) {
            do {
                let driver = try await MacAttentionSessionStore.shared.bindDriver()
                if driver.allowsEmission {
                    do {
                        try store.locked {
                            var rows = try store.load()
                            guard driver.allowsEmission, MacPersonInput.presence()?.here == false else { return }
                            var changed = false
                            for i in rows.indices {
                                for j in rows[i].queued?.indices ?? 0..<0 where rows[i].queued?[j].waitingForMac == true {
                                    rows[i].queued?[j].waitingForMac = nil
                                    rows[i].queued?[j].held = nil
                                    changed = true
                                }
                            }
                            if changed { try store.save(rows) }
                        }
                    } catch { nativeLog("AgentConversationStore: waiting Mac sends stay queued: %@", error.localizedDescription) }
                }
            } catch {
                // Driver authority is required only to unhold Mac sends, not
                // to settle peer sends whose outcome is already recorded.
                nativeLog("AgentConversationStore: waiting sends remain queued; driver authority unavailable: %@", error.localizedDescription)
            }
        }
        guard let rows = try? store.recordsUnlocked() else { return }
        var written: Set<String> = []
        for row in rows where row.agent.hasPrefix("peer:") {
            for send in row.releasing ?? [] {
                do {
                    try await ContactThread.attempt(.state(owner: String(row.agent.dropFirst(5)), sendID: send.id, status: send.status),
                                                    dataRoot: dataRoot)
                    written.insert(row.id + "/" + send.id)
                    releaseFailures.withLock { $0[send.id] = nil }
                } catch {
                    let said = error.localizedDescription
                    if releaseFailures.withLock({ $0.updateValue(said, forKey: send.id) != said }) {
                        nativeLog("AgentConversationStore: send %@'s state stays on its record; its row could not take it: %@", send.id, said)
                    }
                }
            }
        }
        guard !written.isEmpty else { return }
        do {
            try store.locked {
                var rows = try store.load()
                for index in rows.indices {
                    let id = rows[index].id
                    rows[index].releasing?.removeAll { written.contains(id + "/" + $0.id) }
                    if rows[index].releasing?.isEmpty == true { rows[index].releasing = nil }
                }
                try store.save(rows)
            }
        } catch { nativeLog("AgentConversationStore: released sends stay on their records until the next save: %@", error.localizedDescription) }
    }

    /// The conversation owner publishes its identities, including held sends. Contact startup replays the durable owner's current records once.
    func recordExperiences(_ rows: [AgentConversationRecord], dropped: Bool = false) {
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        for row in rows where row.agent.hasPrefix("peer:") && row.phase != "sending" && !dropped {
            let operation = "agent.accept:" + row.operationID
            if AgentConversationDelivery.accepted(row) {
                RepairOwed.settle(root, operation: operation, evidence: .init(source: "agents/conversations", id: row.id))
            } else if row.phase == "waiting", AgentConversationDelivery.claudeInbox(row),
                      case .object(let receipt)? = row.receipt, case .object(let remedy)? = receipt["remedy"], remedy["kind"] == .string("repair"),
                      case .string(let owner)? = remedy["owner"] {
                let tap: String? = if case .string(let tap)? = remedy["tap"] { tap } else { nil }
                let next = remedy["next_call"].flatMap { $0 == .null ? nil : try? $0.serialize(pretty: false) }
                RepairOwed.owe(root, id: row.operationID + ":accept", kind: .message, cause: [row.operationID],
                    operation: operation, owner: owner, words: "Waiting for \(row.name) to accept this message.", nextCall: next, tap: tap)
            }
        }
        // Every row's in one write, ordered with this owner's other writes.
        ExperienceStore.record(root, "agent-conversations") { store in
            let open = try await store.open()
            let contacts = Set(try AgentPeerStore(dataRoot: root).list().map { "peer:" + $0.id })
            for row in rows {
                let evidence = Experience.Ref(source: "agents/conversations", id: row.id)
                let abandoned = dropped || row.stop?.detail == DataRootLife.stoppedReason
                    || (!row.agent.hasPrefix("peer:") && !row.agent.hasPrefix("bot:"))
                    // An empty or unreadable-as-empty list proves no contact was removed.
                    || (row.agent.hasPrefix("peer:") && !contacts.isEmpty && !contacts.contains(row.agent))
                let queued = Set((row.queued ?? []).map(\.id))
                // The row owns every send it began, not just its current operation.
                // Once it moves on, its own exchange says what ended; a missing
                // exchange supplies no acceptance evidence and is let go.
                for experience in open where experience.evidence.contains(evidence) {
                    guard abandoned || (experience.id != row.operationID && !queued.contains(experience.id)) else { continue }
                    let exchange = row.exchanges?.last { $0.id == experience.id }
                    let accepted = !abandoned && (exchange?.reply != nil
                        || (!row.awaitsReply && ["delivered", "read"].contains(exchange?.status ?? "")))
                    try await Self.settleExperience(experience, in: store, accepted: accepted, evidence: evidence)
                }
                if abandoned { continue }
                for (id, obligations) in row.settledObligations ?? [:] {
                    guard let experience = try await store.experience(id) else { continue }
                    for (key, obligation) in obligations where experience.owes[key]?.phase.isSettled == false {
                        let change: ExperienceStore.Change = if let reason = obligation.reason {
                            .letGo(key: key, reason: reason)
                        } else { .obligation(key: key, phase: obligation.phase, evidence: obligation.evidence) }
                        try await store.append([change], to: id)
                    }
                }
                let destination = "agent:" + row.agent
                for item in row.queued ?? [] {
                    let experience = Experience(id: item.id, kind: .message,
                        evidence: [.init(source: "agents/conversations", id: row.id)],
                        addressedTo: [destination], owes: ["deliver": .init(to: "conversation:" + row.id), "accept": .init(to: destination), "answer": .init(to: destination)])
                    if try await store.experience(experience.id) == nil { try await store.begin(experience) }
                    let words = item.text + (item.held.map { "\n\nHeld: " + $0 } ?? "")
                    try await store.append([.face(.init(words: TurnSecretRedactor.redactText(words), artifacts: []))], to: item.id)
                }
                let exchange = row.exchanges?.last { $0.id == row.operationID }
                let current = try await store.experience(row.operationID)
                guard current != nil || exchange != nil || ["sending", "waiting"].contains(row.phase) else { continue }
                let experience = Experience(id: row.operationID, kind: .message,
                    evidence: [.init(source: "agents/conversations", id: row.id)],
                    addressedTo: [destination], owes: ["accept": .init(to: destination), "answer": .init(to: destination)])
                if current == nil { try await store.begin(experience) }
                let delivery = AgentConversationDelivery.of(row, read: false)
                if [.failed, .notDelivered, .unanswered].contains(delivery) {
                    if let current = try await store.experience(experience.id) {
                        try await Self.settleExperience(current, in: store, accepted: false, evidence: evidence,
                                                        reason: delivery == .unanswered ? .expired : .failed)
                    }
                }
                if row.phase != "sending", AgentConversationDelivery.accepted(row), try await store.experience(experience.id)?.owes["accept"]?.phase.isSettled == false {
                    try await store.append([.obligation(key: "accept", phase: .accepted,
                        evidence: .init(source: "agents/conversations", id: row.id))], to: experience.id)
                }
                try await store.append([.face(.init(words: TurnSecretRedactor.redactText(exchange?.reply ?? exchange?.prompt ?? ""),
                    artifacts: []))], to: experience.id)
                guard try await store.experience(experience.id)?.owes["answer"]?.phase.isSettled == false else { continue }
                if delivery == .answered || (!row.awaitsReply && [.delivered, .read].contains(delivery)) {
                    try await store.append([.obligation(key: "answer", phase: .accepted,
                        evidence: .init(source: "agents/conversations", id: row.id))], to: experience.id)
                }
            }
        }
    }

    /// Only unsettled keys move; a send's earlier settlements remain its history.
    private static func settleExperience(_ experience: Experience, in store: ExperienceStore, accepted: Bool,
                                         evidence: Experience.Ref, reason: ObligationPhase.LetGo = .abandoned) async throws {
        let changes: [ExperienceStore.Change] = experience.owes.compactMap { key, obligation in
            guard !obligation.phase.isSettled else { return nil }
            return accepted ? .obligation(key: key, phase: .accepted, evidence: evidence) : .letGo(key: key, reason: reason)
        }
        if !changes.isEmpty { try await store.append(changes, to: experience.id) }
    }
}
