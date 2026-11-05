import ChatTurnContracts
import ApprovalInbox
import Foundation
import PersistenceCore
import TurnTrace
import NativeAgentCore
// Blueprint: | `AgentACPApproval.swift` | `AgentACPApproval` enum; `connect`, `request`, `job` |

/// Permission belongs only to the live request; cancellation retires its card without replaying a turn.
package enum AgentACPApproval {
    /// Capture local turn identity before the protocol callback; a remote sessionId cannot identify the local chat.
    package struct Context: Sendable {
        let origin: JSONValue
        /// The turn the card is filed for.
        let turn: Turn

        package static func current(turn: Turn) -> Context {
            let envelope = TurnEnvelope.current(turn: turn, surface: turn.replyRoute?.surface ?? "chat")
            let route = envelope.replyRoute
            return Context(origin: .object([
                "sessionId": turn.verifiedSessionID.map(JSONValue.string) ?? .null,
                "surface": .string(route.surface),
                "chatId": envelope.verifiedChatId.map(JSONValue.string) ?? .null,
                "destinationId": route.destinationId.map(JSONValue.string) ?? .null,
                "threadId": route.threadId.map(JSONValue.string) ?? .null,
            ]), turn: turn)
        }
    }

    package static func request(_ request: JSONValue, peer: AgentPeerContact,
                        context: Context,
                        dataRoot: URL,
                        inbox: SwiftNativeApprovalInbox) async throws -> Bool {
        try Task.checkCancellation()
        if PeerTrust.ownerTrusts("peer:" + peer.id, dataRoot: dataRoot) { return true }
        // Only a bounded, redacted preview may leave the live request.
        let redacted = try TurnTraceRedactor.redactValue(request).serialize(pretty: false)
        let preview = String(redacted.prefix(4000))
        return try await resolve(.object([
            "title": .string("Allow \(peer.name) to do this once?"),
            "action": .string("agent.acp.permission"), "risk": .string("confirm"),
            "reason": .string("""
                The other agent is asking to act on this Mac. Your answer is sent to that agent for this request. This app asks only when the other \
                agent asks; this card does not control everything that program can do.
                """),
            "payload": .object(["kind": .string("agent_acp_live_approval"),
                                "origin": context.origin,
                                "peer_id": .string(peer.id), "requestPreview": .string(preview),
                                "untrusted_remote_data": .bool(true)]),
            "payloadPreview": .string("Untrusted request from another program:\n" + preview),
            "remoteResolvable": .bool(false), "localOnly": .bool(true)
        ]), turn: context.turn, inbox: inbox)
    }

    /// A job organ asks for something outside its envelope: the person decides, whoever the contact is. No elevation grant or Mac posture answers it.
    /// The card stands in the conversation that commissioned the job.
    package static func job(_ request: JSONValue, asking: String, peer: AgentPeerContact, job: String, commission: AgentJob.Commission,
                            inbox: SwiftNativeApprovalInbox) async throws -> Bool {
        try Task.checkCancellation()
        let redacted = try TurnTraceRedactor.redactValue(request).serialize(pretty: false)
        let preview = String(redacted.prefix(4000))
        return try await resolve(.object([
            "title": .string("Allow \(peer.name) to do this once, for its job?"),
            "action": .string("agent.acp.permission"), "risk": .string("confirm"),
            "reason": .string("""
                \(peer.name) is working on a job you or your agent gave it (\(job)) and asks for something outside that job's reach: \(asking). Your \
                answer is sent to it for this one request; everything inside the job's reach is answered without you.
                """),
            "payload": .object(["kind": .string("agent_acp_live_approval"),
                                "origin": .object(["sessionId": commission.session.map(JSONValue.string) ?? .null,
                                                   "surface": .string(commission.surface)]),
                                "peer_id": .string(peer.id), "job": .string(job), "requestPreview": .string(preview),
                                "untrusted_remote_data": .bool(true)]),
            "payloadPreview": .string("Untrusted request from another program:\n" + preview),
            "remoteResolvable": .bool(false), "localOnly": .bool(true)
        ]), turn: nil, inbox: inbox)
    }

    package static func connect(turn: Turn, _ proposal: AgentHostConnection.Proposal, appName: String,
                        inbox: SwiftNativeApprovalInbox) async throws -> Bool {
        try await resolve(.object([
            "title": .string("Connect \(proposal.row.displayName)?"),
            "action": .string("agent.acp.connect"), "risk": .string("confirm"),
            "reason": .string(AgentHostConnection.cardText(proposal, appName: appName)),
            "payload": .object(["kind": .string("agent_acp_live_approval"),
                "origin": Context.current(turn: turn).origin, "peer_id": .string(proposal.contactID),
                "path": .string(proposal.executable?.path ?? ""),
                "digest": .string(proposal.executable?.digest ?? ""),
                "folder": .string(proposal.workingDirectory.path)]),
            "remoteResolvable": .bool(true), "localOnly": .bool(false)
        ]), turn: turn, inbox: inbox)
    }

    private static func resolve(_ content: JSONValue, turn: Turn?, inbox: SwiftNativeApprovalInbox) async throws -> Bool {
        try Task.checkCancellation()
        let events = await ApprovalLifecycleBus.shared.events()
        let record = try await inbox.create(content, turn: turn)
        do {
            // Subscribe before creating, then read authority to close the create/resolve race; events only trigger rereads.
            var current = try await inbox.get(record.id)
            if current.status == "pending" {
                for await event in events where event.record.id == record.id {
                    try Task.checkCancellation()
                    current = try await inbox.get(record.id)
                    if current.status != "pending" { break }
                }
            }
            try Task.checkCancellation()
            return current.status == "resolved" && current.decision == "approved"
                && current.payload == record.payload && current.resolutionProvenance != nil
        } catch {
            _ = try? await inbox.resolve(record.id, decision: .canceled, decidedBy: "agent conversation ended")
            throw error
        }
    }
}
