import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import AgentConversations

// Blueprint: | `AgentContactTasks+Bridge.swift` | Builder ingress adapts prepared turns to the retained contact task's admission, worker, run binding and terminal receipt |

/// The admission's own authenticated identity and selected conversation
/// bindings. It stores no second copy of the accepted message or attachments.
public struct AgentContactBridgeInput: Codable, Sendable {
    public let principal: AgentBridgePrincipal
    public let persona: String?
    public let ownedSessionID: String?
    public let originID: String?
}

struct AgentContactBridgeClaimConflict: Error, LocalizedError, Sendable {
    var detail: String? = nil
    var errorDescription: String? {
        "A new completion claim cannot establish a fresh canonical admission. "
            + (detail.map { $0 + ". " } ?? "Existing admission evidence is retained. ")
            + "Repair the completion receipt from that exact task and run; no work was repeated."
    }
}

extension AgentContactTasks {
    /// The bridge supplies its routing and presentation; the retained task owns
    /// accepted execution. Neither the HTTP wait nor its response latch owns it.
    func sendBridge(context: String, request: String, principal: AgentBridgePrincipal, digest: String,
                    binding: AgentContactBridgeInput?, completionAdmission: CodexCompletionLifecycle.ClaimAdmission? = nil,
                    operation: @escaping @Sendable (@escaping @Sendable (String, String) async throws -> Void) async throws -> AgentContactOutcome) async throws -> AgentContactTask {
        guard bridgeIsActive else { throw CancellationError() }
        let id = "na3.\(context).\(request)"
        guard NativeAgentA2AWire.locator(id) != nil else {
            throw AgentContactFailure(code: -32602, message: "The bridge task identity is invalid; nothing was admitted.")
        }
        let key = AgentPeerReplayClaimStore.key(principal: principal.id, protocolName: "builder", messageID: id)
        let needsFreshCanonical = completionAdmission?.decision == .start && completionAdmission?.resumesNotStarted != true
        let claim: AgentPeerReplayClaimStore.Outcome
        do { claim = try claims.claim(key: key, digest: digest) }
        catch {
            if needsFreshCanonical { throw AgentContactBridgeClaimConflict(detail: error.localizedDescription) }
            throw error
        }
        if needsFreshCanonical, claim != .claimed { throw AgentContactBridgeClaimConflict() }
        switch claim {
        case .replay:
            guard completionAdmission?.resumesNotStarted == true else { return try get(id, owner: principal.id) }
            // Only the completion owner's positive `start` verdict after
            // markNotStarted authorizes another attempt at its unstarted turn.
            if let worker = records[id]?.worker { await worker.value }
            var task = try get(id, owner: principal.id)
            guard task.state == .failed || task.state == .submitted,
                  task.parts.isEmpty, task.text.isEmpty else {
                throw AgentContactFailure(code: -32004, message: "The completion owner permitted an unstarted attempt, but its canonical task retains another outcome. Repair their exact receipts; no work was repeated.")
            }
            if records[id] == nil, records.count >= capacity {
                guard let oldest = order.first(where: { records[$0]?.task.state.terminal == true }) else {
                    throw AgentContactFailure(code: -32004, message: "Too much work is active. Try again later.")
                }
                records.removeValue(forKey: oldest); order.removeAll { $0 == oldest }
                pushConfigs.removeValue(forKey: oldest)
            }
            task.state = .submitted; task.detail = nil; task.failure = nil; task.replyRecovery = nil
            task.toolResult = nil
            try retain(task)
            records[id] = Record(task: task)
            if !order.contains(id) { order.append(id) }
            startWorker(id) {
                try await operation { session, run in try await self.bindRun(id, session: session, run: run) }
            }
            return task
        case .claimed: break
        default: throw AgentContactFailure(code: -32004, message: "This request is already active or was used for different content. Read its retained task; do not resend.")
        }
        do {
            let saved: [AgentContactTask]
            do { saved = try retainedTasks(id: id, owner: principal.id) }
            catch {
                if needsFreshCanonical { throw AgentContactBridgeClaimConflict(detail: error.localizedDescription) }
                throw error
            }
            guard records[id] == nil, saved.isEmpty else {
                if needsFreshCanonical { throw AgentContactBridgeClaimConflict() }
                throw AgentContactFailure(code: -32602, message: "This request already has retained task evidence. Read its result; do not resend.")
            }
            if records.count >= capacity {
                guard let oldest = order.first(where: { records[$0]?.task.state.terminal == true }) else {
                    throw AgentContactFailure(code: -32004, message: "Too much work is active. Try again later.")
                }
                records.removeValue(forKey: oldest)
                order.removeAll { $0 == oldest }
                pushConfigs.removeValue(forKey: oldest)
            }
            var task = AgentContactTask(id: id, context: context, owner: principal.id)
            task.lifeID = try DataRootLife.current(in: dataRoot)
            task.bridgeInput = binding
            try retain(task)
            records[id] = Record(task: task)
            order.append(id)
            if let detail = claims.recordReceipt(key: key, digest: digest, receipt: ["taskID": id]) {
                task.detail = detail
                try retain(task)
                records[id]?.task = task
            }
            startWorker(id) {
                try await operation { session, run in try await self.bindRun(id, session: session, run: run) }
            }
            return task
        } catch { claims.release(key: key); throw error }
    }

    /// Suspension only: a canceled reader cannot cancel the accepted worker.
    func settledBridge(_ id: String, owner: String) async throws -> AgentContactTask {
        if let worker = records[id]?.worker { await worker.value }
        return try get(id, owner: owner)
    }
}
