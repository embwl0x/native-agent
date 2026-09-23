import Foundation
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

enum GrokInboundReply {
    /// Local correlation is authority; stdin cannot choose the conversation.
    /// Claim before enqueue so ambiguous delivery cannot duplicate a turn.
    static func receive(_ reply: GrokReplyInput, principal: AgentBridgePrincipal, dataRoot: URL,
                        deliver: (@Sendable (GrokPendingRequest, String, AgentBridgePrincipal) async throws -> String)? = nil) async throws {
        guard principal.peerID == principal.id,
              let contact = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == principal.id }),
              contact.transport == .grokBot, contact.grokSetup == "set up" else { throw GrokLinkCredential.Failure.invalid }
        let store = GrokRequestStore(dataRoot: dataRoot)
        let pending = try store.claimReply(reply, peer: principal.id)
        let peer = AgentBridgePrincipal(id: principal.id, peerID: principal.id, elevated: false, displayName: contact.name)
        let run: String
        do {
            if let deliver { run = try await deliver(pending, reply.text, peer) }
            else { run = try await enqueue(pending, text: reply.text, peer: peer, dataRoot: dataRoot) }
        } catch {
            // Queuing failed: put the claim back so the reply can still land.
            _ = try? store.update(reply.message_id, peer: peer.id) { $0.state = "accepted" }
            throw error
        }
        try store.update(reply.message_id, peer: peer.id) { $0.state = "answered"; $0.runID = run }
        // 2026-09-22 WHY: no background read covers Grok, so its conversation
        // row stayed "waiting" forever. Settle the exact row that sent this id.
        let conversations = AgentConversationStore(dataRoot: dataRoot)
        if let row = try? conversations.records().first(where: {
            $0.agent == "peer:" + peer.id && $0.readInput?["message_id"] == .string(reply.message_id) }) {
            _ = try? conversations.update(id: row.id, operationID: row.operationID) {
                $0.receipt = AgentConversationStore.cacheReceipt(.object(["status": .string("answered"), "completed": .bool(true),
                    "message_id": .string(reply.message_id), "reply": .string(reply.text), "untrusted_remote_data": .bool(true)]))
                $0.phase = "ready"
            }
        }
        // A correlated reply also proves the original outbound message reached this run.
        AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, inbound: true)
        AgentPeerStore(dataRoot: dataRoot).recordRoundTrip(peerID: peer.id, workspace: "Grok Bot conversation")
    }

    private static func enqueue(_ pending: GrokPendingRequest, text: String, peer: AgentBridgePrincipal, dataRoot: URL) async throws -> String {
        let client = makeNativeAgentAppChatOrchestrationClient(profile: .bridge, dataRoot: dataRoot)
        let envelope = TurnEnvelope(surface: AgentBridgeSurface.id, agent: "peer", verifiedUserId: peer.id,
            commandSignatureVerified: true, declaredRemote: true)
        let origin = ChatMessageOrigin(surface: "agent-bridge", agent: "agent", authored: .agent)
        // This credential can only answer a message this app sent, so say so:
        // unframed, the answer read as a new request and the question was re-asked
        // (driven 09-20).
        let message = AgentBridgeSurface.turnHeader(peerName: peer.displayName, elevated: false)
            + "[This is \(peer.displayName ?? "the other agent")'s answer to the message you sent it in this conversation. The exchange is complete: do not send the question again. Tell the person the answer once.]\n" + text
        let enqueued = try await ChatToolSessionContext.$envelope.withValue(envelope) {
            try await ChatPersistenceContext.$originProvenance.withValue(origin) {
                try await client.enqueueUserMessage(message: message, sessionId: pending.conversationID,
                    persona: nil, surface: AgentBridgeSurface.id, attachments: [], mechanicalRow: nil)
            }
        }
        Task {
            _ = try? await ChatToolSessionContext.$envelope.withValue(envelope) {
                try await ChatPersistenceContext.$originProvenance.withValue(origin) {
                    try await ChatPersistenceContext.$pinnedTurnRunID.withValue(enqueued.runId) {
                        try await client.chat(message: message, sessionId: enqueued.sessionId, model: "", reasoningEffort: "",
                            fileAccess: "auto", attachments: [], persona: nil, surface: AgentBridgeSurface.id, suppressUserAppend: true)
                    }
                }
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .chatTurnCompleted, object: enqueued.sessionId)
            }
        }
        return enqueued.runId
    }
}
