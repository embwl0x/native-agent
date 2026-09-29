import GrokLink
import Foundation
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

public struct GrokInboundReply: Sendable {
    let clients: any AgentContactClients
    /// Hand-overs this root is running, so a launch pass never starts a second one.
    private let running = Running()

    init(clients: any AgentContactClients) { self.clients = clients }

    /// Local correlation is authority; stdin cannot choose the conversation.
    /// Claim before enqueue so ambiguous delivery cannot duplicate a turn.
    public func receive(_ reply: GrokReplyInput, principal: AgentBridgePrincipal, dataRoot: URL,
                        deliver: (@Sendable (GrokPendingRequest, String, AgentBridgePrincipal) async throws -> String)? = nil) async throws {
        guard principal.peerID == principal.id,
              let contact = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == principal.id }),
              contact.transport == .grokBot, contact.grokSetup == "set up" else { throw GrokLinkCredential.Failure.invalid }
        let store = GrokRequestStore(dataRoot: dataRoot)
        let pending = try store.claimReply(reply, peer: principal.id)
        let peer = AgentBridgePrincipal(id: principal.id, peerID: principal.id, elevated: false, displayName: contact.name)
        var run = ""
        if let deliver {
            do { run = try await deliver(pending, reply.text, peer) } catch {
                // Queuing failed: put the claim back so the reply can still land.
                _ = try? store.update(reply.message_id, peer: peer.id) { $0.state = "accepted" }
                throw error
            }
        }
        let handsOver = deliver == nil && pending.quiet != true
        let answered = try store.update(reply.message_id, peer: peer.id) {
            $0.state = "answered"; $0.reply = reply.text; $0.runID = run.isEmpty ? nil : run
            if handsOver { $0.handOver = "pending" }
        }
        // 2026-09-22 WHY: no background read covers Grok, so its conversation
        // row stayed "waiting" forever. Settle the exact row that sent this id;
        // a late answer to an earlier exchange lands on that exchange only.
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
        if handsOver { handOver(answered, text: reply.text, peer: peer, dataRoot: dataRoot) }
    }

    /// The answer becomes her turn only when the asking turn did not already
    /// take it with `wait`, and only once any turn in that chat has finished:
    /// two turns at once both acted on "plum" and the follow-up went twice
    /// (walk 3, 09-25). The answer is saved above; `handOver` on the request
    /// says durably whether it has become her turn yet.
    private func handOver(_ pending: GrokPendingRequest, text: String, peer: AgentBridgePrincipal, dataRoot: URL) {
        struct Taken: Error {}
        guard running.claim(pending.messageID) else { return }
        Task {
            defer { running.release(pending.messageID) }
            let store = GrokRequestStore(dataRoot: dataRoot), id = pending.messageID
            func mark(_ state: String, if current: String) {
                _ = try? store.update(id, peer: peer.id) { if $0.handOver == current { $0.handOver = state } }
            }
            if await GrokBotRoute.takenByWaiter(peer: peer.id, messageID: id, dataRoot: dataRoot) {
                return mark("taken by wait", if: "pending")
            }
            var why = ""
            for _ in 0..<20 {
                do {
                    _ = try await TurnAdmission.shared.run(sessionID: pending.conversationID) {
                        // Only a still-pending hand-over starts a turn; a wait later in
                        // the turn that just finished may have taken it meanwhile.
                        let claimed = try store.update(id, peer: peer.id) {
                            if $0.seen == true, $0.handOver == "pending" { $0.handOver = "taken by wait" }
                            else if $0.handOver == "pending" { $0.handOver = "handing over" }
                        }
                        guard claimed.handOver == "handing over" else { throw Taken() }
                        return try await enqueue(pending, text: text, peer: peer, dataRoot: dataRoot)
                    }
                    break
                } catch is Taken { return } catch {
                    // Its turn row never got written: pending again, and tried again.
                    // Once written it went (a failed turn is that turn's own failure).
                    guard (try? store.read(id, peer: peer.id))?.handOver != "handed over" else { break }
                    mark("pending", if: "handing over")
                    why = error.localizedDescription
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            if !why.isEmpty { mark("not handed over: " + why, if: "pending") }
            await MainActor.run { NotificationCenter.default.post(name: .chatTurnCompleted, object: pending.conversationID) }
        }
    }

    /// Once per launch: answers saved but not yet her turn go again; one cut
    /// off mid-hand-over is marked, never repeated (it may already be her turn).
    func resumeHandOvers(dataRoot: URL) {
        let store = GrokRequestStore(dataRoot: dataRoot)
        let files = (try? FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)) ?? []
        let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count <= 96 * 1024,
                  let saved = try? JSONDecoder().decode(GrokPendingRequest.self, from: data), let text = saved.reply,
                  ["pending", "handing over"].contains(saved.handOver ?? "") else { continue }
            if saved.handOver == "handing over" {
                _ = try? store.update(saved.messageID, peer: saved.peerID) {
                    if $0.handOver == "handing over" { $0.handOver = "interrupted: the answer is saved; the app stopped while handing it over, so it may not have reached her as a turn" }
                }
                continue
            }
            guard let contact = contacts.first(where: { $0.id == saved.peerID && $0.transport == .grokBot }) else { continue }
            handOver(saved, text: text, peer: AgentBridgePrincipal(id: contact.id, peerID: contact.id, elevated: false,
                displayName: contact.name), dataRoot: dataRoot)
        }
    }

    private final class Running: @unchecked Sendable {
        private let lock = NSLock(); private var ids: Set<String> = []
        func claim(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
        func release(_ id: String) { lock.withLock { _ = ids.remove(id) } }
    }

    private func enqueue(_ pending: GrokPendingRequest, text: String, peer: AgentBridgePrincipal,
                                dataRoot: URL) async throws -> ChatOrchestration.ChatResponse {
        let client = clients.bridgeChatClient()
        let envelope = TurnEnvelope(surface: AgentBridgeSurface.id, agent: "peer", verifiedUserId: peer.id,
            commandSignatureVerified: true, declaredRemote: true)
        let origin = ChatMessageOrigin(surface: "agent-bridge", agent: "agent", authored: .agent)
        // This credential can only answer a message this app sent, so say so:
        // unframed, the answer read as a new request and the question was re-asked
        // (driven 09-20).
        let message = AgentBridgeSurface.turnHeader(peerName: peer.displayName, elevated: false)
            + "[This is \(peer.displayName ?? "the other agent")'s answer to the message you sent it in this conversation. The exchange is complete: do not send the question again. Tell the person the answer once.]\n" + text
        let request = TurnRequest(message: message, sessionID: pending.conversationID, surface: AgentBridgeSurface.id,
                                  envelope: envelope, origin: origin)
        let enqueued = try await request.enqueue(on: client)
        _ = try? GrokRequestStore(dataRoot: dataRoot).update(pending.messageID, peer: peer.id) {
            $0.runID = enqueued.runId; $0.handOver = "handed over"
        }
        return try await request.consuming(enqueued).chat(on: client)
    }
}
