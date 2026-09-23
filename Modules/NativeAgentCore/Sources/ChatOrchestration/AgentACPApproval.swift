import ApprovalInbox
import Foundation
import PersistenceCore

/// A permission belongs to this live request only. Resolution uses the existing
/// inbox and lifecycle edges; cancellation retires the card, never replays a turn.
enum AgentACPApproval {
    /// Capture at the initiating turn, before the protocol reader calls back.
    /// The other agent's sessionId is never the local chat's identity.
    struct Context: Sendable {
        let origin: JSONValue

        static var current: Context {
            let envelope = TurnEnvelope.current(surface: ChatToolSessionContext.replyRoute?.surface ?? "chat")
            let route = envelope.replyRoute
            return Context(origin: .object([
                "sessionId": ChatToolSessionContext.verifiedSessionId.map(JSONValue.string) ?? .null,
                "surface": .string(route.surface),
                "chatId": envelope.verifiedChatId.map(JSONValue.string) ?? .null,
                "destinationId": route.destinationId.map(JSONValue.string) ?? .null,
                "threadId": route.threadId.map(JSONValue.string) ?? .null,
            ]))
        }
    }

    /// Never launch the replacement to inspect its version before consent.
    /// The refused message is not replayed after this fresh setup approval.
    static func renewExecutable(_ contact: AgentPeerContact, store: AgentPeerStore,
                                inbox: any ApprovalInboxProtocol) async throws -> Bool {
        guard let id = AgentPeerStore.hostRowID(contact.endpoint),
              let row = AgentHostDirectory.row(named: id), row.acp != nil,
              let path = contact.approvedExecutablePath, let folder = contact.acpWorkingDirectory else { return false }
        let current = try? AgentACPExecutable.capture(path: path)
        let proposal = AgentHostConnection.Proposal(row: row, command: "", descriptorPath: "",
            existing: contact, workingDirectory: URL(fileURLWithPath: folder), contactID: contact.id,
            executable: current, executablePath: current?.path)
        guard try await connect(proposal, appName: "NativeAgent", inbox: inbox), current?.isCurrent == true else { return false }
        _ = try AgentHostConnection.connect(proposal: proposal, store: store)
        return true
    }

    static func request(_ request: JSONValue, peer: AgentPeerContact,
                        context: Context = .current,
                        inbox: any ApprovalInboxProtocol) async throws -> Bool {
        // Only a redacted, bounded preview leaves this live request. The raw
        // protocol object is never needed to resolve or replay an inbox card.
        let redacted = try TurnTraceRedactor.redactValue(request).serialize(pretty: false)
        let preview = String(redacted.prefix(4000))
        return try await resolve(.object([
            "title": .string("Allow \(peer.name) to do this once?"),
            "action": .string("agent.acp.permission"), "risk": .string("confirm"),
            "reason": .string("The other agent is asking to act on this Mac. Your answer is sent to that agent for this request. This app asks only when the other agent asks; this card does not control everything that program can do."),
            "payload": .object(["kind": .string("agent_acp_live_approval"),
                                "origin": context.origin,
                                "peer_id": .string(peer.id), "requestPreview": .string(preview),
                                "untrusted_remote_data": .bool(true)]),
            "payloadPreview": .string("Untrusted request from another program:\n" + preview),
            "remoteResolvable": .bool(false), "localOnly": .bool(true)
        ]), inbox: inbox)
    }

    static func connect(_ proposal: AgentHostConnection.Proposal, appName: String,
                        inbox: any ApprovalInboxProtocol) async throws -> Bool {
        try await resolve(.object([
            "title": .string("Connect \(proposal.row.displayName)?"),
            "action": .string("agent.acp.connect"), "risk": .string("confirm"),
            "reason": .string(AgentHostConnection.cardText(proposal, appName: appName)),
            "payload": .object(["kind": .string("agent_acp_live_approval"),
                "origin": Context.current.origin, "peer_id": .string(proposal.contactID),
                "path": .string(proposal.executable?.path ?? ""),
                "digest": .string(proposal.executable?.digest ?? ""),
                "folder": .string(proposal.workingDirectory.path)]),
            "remoteResolvable": .bool(true), "localOnly": .bool(false)
        ]), inbox: inbox)
    }

    private static func resolve(_ content: JSONValue, inbox: any ApprovalInboxProtocol) async throws -> Bool {
        try Task.checkCancellation()
        let events = await ApprovalLifecycleBus.shared.events()
        let record = try await inbox.create(content)
        do {
            // Subscribe before creating, then read the authority to close the
            // create/resolve race. Events only tell us when to read again.
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
