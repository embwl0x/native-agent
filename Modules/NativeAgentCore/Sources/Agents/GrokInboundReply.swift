import AgentWorkspace
import CryptoKit
import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `GrokInboundReply.swift` | Root-retained handover tasks deduplicate by message until actual exit; canonical `TurnAdmission.admittedRun` registers accepted runs for Stop/quit before session admission; `settle` writes their terminal handover result and releases ownership; the continuation lifecycle closes admission, cancels and joins them before closing live publication |

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
        let pending = try store.claimReply(reply, peer: principal.id)
        let peer = AgentBridgePrincipal(id: principal.id, peerID: principal.id, elevated: contact.elevationAllowed, displayName: contact.name)
        let handsOver = pending.quiet != true
        let answered = try store.update(reply.message_id, peer: peer.id) {
            $0.state = "answered"; $0.reply = reply.text; $0.runID = nil
            if handsOver { $0.handOver = "pending" }
        }
        // Settle only the conversation row or exchange matching this reply's message ID.
        let conversations = AgentConversationStore(dataRoot: dataRoot)
        let rows = (try? conversations.records())?.filter { $0.agent == "peer:" + peer.id } ?? []
        if let row = rows.first(where: { $0.readInput?["message_id"] == .string(reply.message_id) }) {
            _ = try? conversations.update(id: row.id, operationID: row.operationID) {
                $0.receipt = AgentConversationStore.cacheReceipt(.object(["status": .string("answered"), "completed": .bool(true),
                    "message_id": .string(reply.message_id), "reply": .string(reply.text), "untrusted_remote_data": .bool(true)]))
                $0.phase = "ready"
            }
        } else if let row = rows.first(where: { $0.exchanges?.contains { $0.id == reply.message_id } == true }) {
            _ = try? conversations.settleExchange(id: row.id, exchange: reply.message_id, reply: reply.text)
        }
        // A correlated reply also proves the original outbound message reached this run.
        AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, inbound: true)
        AgentPeerStore(dataRoot: dataRoot).recordRoundTrip(peerID: peer.id, workspace: "Grok Bot conversation")
        // The person asked from Grok's thread: the answer settles there, no agent turn.
        if handsOver { handOver(answered, text: reply.text, peer: peer, dataRoot: dataRoot, continuation: continuation) }
    }

    /// After session admission, only a pending, unconsumed answer becomes a turn.
    /// The saved `handOver` durably records its outcome.
    private func handOver(_ pending: GrokPendingRequest, text: String, peer: AgentBridgePrincipal, dataRoot: URL,
                          continuation: AgentConversationContinuation) {
        running.start(pending.messageID) {
            let store = GrokRequestStore(dataRoot: dataRoot), id = pending.messageID
            var terminal = "handed over"
            do {
                if await GrokBotRoute.takenByWaiter(peer: peer.id, messageID: id, dataRoot: dataRoot) {
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
                            if $0.handOver == "pending" { $0.handOver = "running"; $0.runID = runID }
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
            }
            let result = terminal
            await settle {
                _ = try? store.update(id, peer: peer.id) {
                    if ["pending", "running"].contains($0.handOver ?? "") { $0.handOver = result }
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: pending.conversationID)
                }
            }
        }
    }

    /// Once per launch: answers saved but not yet her turn go again; one cut
    /// off mid-hand-over is marked, never repeated (it may already be her turn).
    func resumeHandOvers(dataRoot: URL, continuation: AgentConversationContinuation) {
        running.open()
        let store = GrokRequestStore(dataRoot: dataRoot)
        do { try store.pruneSettled() }
        catch { nativeLog("Grok request retention failed: %@", error.localizedDescription) }
        let files = (try? FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)) ?? []
        let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count <= 96 * 1024,
                  let identity = try? JSONDecoder().decode(GrokPendingRequest.self, from: data),
                  let saved = try? store.read(identity.messageID, peer: identity.peerID), let text = saved.reply,
                  ["pending", "running", "handing over"].contains(saved.handOver ?? "") else { continue }
            if ["running", "handing over"].contains(saved.handOver ?? "") {
                _ = try? store.update(saved.messageID, peer: saved.peerID) {
                    $0.handOver = "interrupted: the answer is saved; the app stopped while handing it over, so it may not have reached her as a turn"
                }
                continue
            }
            if saved.seen == true {
                // Seen with its hand-over still pending: only a wait could leave
                // that (saved before `shown` named the door, or cut off between).
                _ = try? store.update(saved.messageID, peer: saved.peerID) {
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
        guard let contact = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peer.id && $0.transport == .grokBot }) else {
            throw GrokLinkCredential.Failure.invalid
        }
        let peer = AgentBridgePrincipal(id: contact.id, peerID: contact.id, elevated: contact.elevationAllowed, displayName: contact.name)
        let envelope = TurnEnvelope(surface: peer.surface, agent: "peer", verifiedUserId: peer.id,
            commandSignatureVerified: true, deliveryRoute: route.chatToolReplyRoute, declaredRemote: !peer.elevated)
        let origin = ChatMessageOrigin(surface: peer.surface, agent: "agent", authored: .agent)
        // This credential answers only a message this app sent; name that
        // message so a late answer cannot be mistaken for a newer exchange.
        let asked = GrokBotRoute.thread(peer: peer.id, dataRoot: dataRoot)
            .first { $0.id == pending.messageID }.map { "your message \u{201C}" + HerScreen.clip($0.prompt, 120) + "\u{201D}" }
        let message = AgentBridgeSurface.turnHeader(peerName: peer.displayName, elevated: peer.elevated)
            + "[This is \(peer.displayName ?? "the other agent")'s answer to \(asked ?? "a message you sent it whose text is no longer kept") in this conversation. The exchange is complete: do not send the question again. Tell the person the answer once.]\n" + text
        return TurnRequest(message: message, sessionID: pending.conversationID, surface: peer.surface, envelope: envelope,
                           replyRoute: route.chatToolReplyRoute, origin: origin, pinnedRunID: runID, codexCompletion: binding)
    }
}
