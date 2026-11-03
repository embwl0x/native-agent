import AgentWorkspace
import CryptoKit
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `GrokInboundReply.swift` | Atomic request-store reply/hand-over retention and repeatable conversation projection precede root-retained handover tasks, which deduplicate by message until actual exit; canonical `TurnAdmission.admittedRun` registers accepted runs for Stop/quit before session admission; `settle` writes their terminal handover result and releases ownership; the continuation lifecycle closes admission, cancels and joins them before closing live publication |

public struct GrokInboundReply: Sendable {
    let clients: any AgentContactClients
    /// This root retains each hand-over through canonical turn admission and
    /// completion delivery, so a launch pass never starts a second one.
    private let running = Running()

    init(clients: any AgentContactClients) { self.clients = clients }

    func stop() async { await running.stop() }

    /// Local correlation is authority; stdin cannot choose the conversation.
    /// Claim before enqueue so ambiguous delivery cannot duplicate a turn.
    public func receive(_ reply: GrokReplyInput, principal: AgentBridgePrincipal, dataRoot: URL,
                        continuation: AgentConversationContinuation) async throws {
        guard principal.peerID == principal.id,
              let contact = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == principal.id }),
              contact.transport == .grokBot, contact.grokSetup == "set up" else { throw GrokLinkCredential.Failure.invalid }
        let store = GrokRequestStore(dataRoot: dataRoot)
        let answered = try store.claimReply(reply, peer: principal.id)
        let peer = AgentBridgePrincipal(id: principal.id, peerID: principal.id, elevated: contact.elevationAllowed, displayName: contact.name)
        try reconcile(answered, dataRoot: dataRoot)
        // The person asked from Grok's thread: settle there, without a turn.
        if answered.handOver == "pending" { handOver(answered, text: reply.text, peer: peer, dataRoot: dataRoot, continuation: continuation) }
    }

    /// Repeatable projection of the one saved answer, including after launch
    /// or a failed webhook response. Never claim another reply to repair it.
    private func reconcile(_ answered: GrokPendingRequest, dataRoot: URL) throws {
        guard let text = answered.reply else { throw GrokLinkCredential.Failure.invalid }
        // The journal binds the protocol message to its internal operation UUID.
        let conversations = AgentConversationStore(dataRoot: dataRoot)
        let rows = try conversations.records().filter { $0.agent == "peer:" + answered.peerID }
        if let row = rows.first(where: { row in
            row.exchanges?.contains { $0.id == row.operationID && GrokBotRoute.messageID(for: $0) == answered.messageID } == true
        }) {
            _ = try conversations.update(id: row.id, operationID: row.operationID) {
                AgentConversationSession.absorb(GrokBotRoute.projection(answered), into: &$0)
            }
        } else if let row = rows.first(where: { $0.exchanges?.contains { GrokBotRoute.messageID(for: $0) == answered.messageID } == true }),
                  let exchange = row.exchanges?.first(where: { GrokBotRoute.messageID(for: $0) == answered.messageID }) {
            _ = try conversations.settleExchange(id: row.id, exchange: exchange.id, reply: text)
        }
        // A correlated reply also proves the original outbound message reached this run.
        AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: answered.peerID, inbound: true)
        AgentPeerStore(dataRoot: dataRoot).recordRoundTrip(peerID: answered.peerID, workspace: "Grok Bot conversation")
    }

    /// After session admission, only a pending, unconsumed answer becomes a turn.
    /// The saved `handOver` durably records its outcome.
    private func handOver(_ pending: GrokPendingRequest, text: String, peer: AgentBridgePrincipal, dataRoot: URL,
                          continuation: AgentConversationContinuation) {
        running.start(pending.messageID) {
            let store = GrokRequestStore(dataRoot: dataRoot), id = pending.messageID
            var terminal = "handed over"
            do {
                if try await GrokBotRoute.takenByWaiter(peer: peer.id, messageID: id, dataRoot: dataRoot) {
                    throw AgentConversationContinuation.NotStarted()
                }
                try Task.checkCancellation()
                // Its answer goes back to the door it was asked from, kept with the request.
                guard let route = pending.route else {
                    throw AgentConversationStore.Failure(message: "this request was sent before its asking door was kept with it, so the answer has no way back. It is saved here; tell the person in the conversation it was asked from.")
                }
                let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                let answered = try await continuation.answer("grok-reply:" + id, digest: digest, session: pending.conversationID,
                                                             route: route, principal: "peer:" + peer.id) { runID, binding in
                    try await TurnAdmission.admittedRun(dataRoot: dataRoot, sessionID: pending.conversationID,
                                                        runID: runID, waitForCapacity: true) {
                        // Recheck pending after admission: wait or room may have consumed it.
                        let claimed = try store.update(id, peer: peer.id) {
                            if $0.handOver == "pending" { $0.handOver = "running"; $0.runID = runID; $0.handOverError = nil }
                        }
                        guard claimed.handOver == "running", claimed.runID == runID else { throw AgentConversationContinuation.NotStarted() }
                        return try await request(pending, text: text, peer: peer, route: route, runID: runID, binding: binding, dataRoot: dataRoot)
                            .chat(on: clients.bridgeChatClient())
                    }
                }
                if case .held = answered {
                    throw AgentConversationStore.Failure(message: "its delivery is already recorded as in progress or uncertain; no second turn was started.")
                }
            } catch is AgentConversationContinuation.NotStarted { terminal = "taken by wait or room" }
            catch is CancellationError {
                terminal = "stopped: the answer is saved; any admitted turn keeps what it produced, and no second turn will be started"
            } catch {
                terminal = "not handed over: " + error.localizedDescription
                nativeLog("Grok handover %@ remains owed: %@", id, error.localizedDescription)
            }
            let result = terminal
            await settle {
                do {
                    _ = try store.update(id, peer: peer.id) {
                        if $0.handOver == "pending", result.hasPrefix("not handed over:") {
                            $0.handOverError = result
                        } else if ["pending", "running"].contains($0.handOver ?? "") { $0.handOver = result }
                    }
                } catch { nativeLog("Grok handover settlement %@ could not be saved: %@", id, error.localizedDescription) }
                await MainActor.run {
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: pending.conversationID)
                }
            }
        }
    }

    /// Once per launch: answers saved but not yet her turn go again; one cut
    /// off mid-hand-over is marked, never repeated (it may already be her turn).
    func resumeHandOvers(dataRoot: URL, continuation: AgentConversationContinuation) throws {
        running.open()
        let store = GrokRequestStore(dataRoot: dataRoot)
        try store.pruneSettled()
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return }
        let contacts = try AgentPeerStore(dataRoot: dataRoot).list()
        for file in files where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            guard data.count <= 96 * 1024 else { throw GrokLinkCredential.Failure.invalid }
            let identity = try JSONDecoder().decode(GrokPendingRequest.self, from: data)
            let saved = try store.read(identity.messageID, peer: identity.peerID)
            guard let text = saved.reply else { continue }
            try reconcile(saved, dataRoot: dataRoot)
            guard ["pending", "running", "handing over"].contains(saved.handOver ?? "") else { continue }
            if ["running", "handing over"].contains(saved.handOver ?? "") {
                _ = try store.update(saved.messageID, peer: saved.peerID) {
                    $0.handOver = "interrupted: the answer is saved; the app stopped while handing it over, so it may not have reached her as a turn"
                }
                continue
            }
            if saved.seen == true {
                // Seen with its hand-over still pending: only a wait could leave
                // that (saved before `shown` named the door, or cut off between).
                _ = try store.update(saved.messageID, peer: saved.peerID) {
                    if $0.seen == true, $0.handOver == "pending" { $0.handOver = "taken by wait" }
                }
                continue
            }
            guard let contact = contacts.first(where: { $0.id == saved.peerID && $0.transport == .grokBot }) else { continue }
            handOver(saved, text: text, peer: AgentBridgePrincipal(id: contact.id, peerID: contact.id, elevated: contact.elevationAllowed,
                displayName: contact.name), dataRoot: dataRoot, continuation: continuation)
        }
    }

    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [String: Task<Void, Never>] = [:]
        private var closed = false
        func open() { lock.withLock { closed = false } }

        func start(_ id: String, operation: @escaping @Sendable () async -> Void) {
            lock.withLock {
                guard !closed, tasks[id] == nil else { return }
                // Creation and retention share the lock with shutdown. Even a
                // synchronous exit cannot release before the handle is kept.
                tasks[id] = Task {
                    await operation()
                    await settle { self.release(id) }
                }
            }
        }

        private func release(_ id: String) { lock.withLock { _ = tasks.removeValue(forKey: id) } }

        func stop() async {
            let pending = lock.withLock {
                closed = true
                return Array(tasks.values)
            }
            pending.forEach { $0.cancel() }
            for task in pending { await task.value }
        }
    }

    /// Her turn on the answer, in the conversation that asked, answering to its door.
    private func request(_ pending: GrokPendingRequest, text: String, peer: AgentBridgePrincipal, route: AgentBridgeCompletionRoute,
                         runID: String, binding: CodexCompletionTranscriptBinding, dataRoot: URL) throws -> TurnRequest {
        let contacts = try AgentPeerStore(dataRoot: dataRoot).list()
        guard let contact = contacts.first(where: { $0.id == peer.id && $0.transport == .grokBot }) else {
            throw GrokLinkCredential.Failure.invalid
        }
        let peer = AgentBridgePrincipal(id: contact.id, peerID: contact.id, elevated: contact.elevationAllowed, displayName: contact.name)
        let envelope = TurnEnvelope(surface: peer.surface, agent: "peer", verifiedUserId: peer.id,
            commandSignatureVerified: true, deliveryRoute: route.chatToolReplyRoute, declaredRemote: !peer.elevated)
        let origin = ChatMessageOrigin(surface: peer.surface, agent: "agent", authored: .agent)
        // This credential answers only a message this app sent; name that
        // message so a late answer cannot be mistaken for a newer exchange.
        let asked = try GrokBotRoute.thread(peer: peer.id, dataRoot: dataRoot)
            .first { $0.messageID == pending.messageID }.map { "your message \u{201C}" + HerScreen.clip($0.prompt, 120) + "\u{201D}" }
        // Her reply here returns to whoever asked in this conversation, not to the
        // agent who answered. Unnamed, she thanked Grok into Claude's conversation
        // and the words never reached him (10-31).
        let asker = route.destinationId.flatMap { destination in
            contacts.first { $0.id == destination || "peer:" + $0.id == destination }.flatMap { $0.name }
        } ?? HerScreen.names(dataRoot).person
        let answerer = peer.displayName ?? "the other agent"
        let message = AgentBridgeSurface.turnHeader(peerName: peer.displayName, elevated: peer.elevated)
            + "[This is \(answerer)'s answer to \(asked ?? "your message identified by " + pending.messageID + "; its original text is absent from the saved conversation") in this conversation. The exchange is complete: do not send the question again. Your reply here goes to \(asker), not to \(answerer): tell \(asker) the answer once. Anything for \(answerer) goes in a message to \(answerer).]\n" + text
        return TurnRequest(message: message, sessionID: pending.conversationID, surface: peer.surface, envelope: envelope,
                           replyRoute: route.chatToolReplyRoute, origin: origin, pinnedRunID: runID, codexCompletion: binding)
    }
}
