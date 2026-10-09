import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import AgentConversations

/// Enforces `PeerDataTaint` inside the per-turn chat dispatch chain.
///
/// NOT a tool fence any more (2026-09-15). Effects raise the person's own
/// permission card in `AutonomyGatedDispatcher`, which reads the same taint
/// box this one latches. What survives here is the one thing that has to see
/// the tool's ARGUMENTS: Agent's provenance requirement on her own memory
/// notes.
public final class PeerDataTaintDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    /// The peers the PERSON has elevated in Trust → Connected agents. Nil on
    /// surfaces with no peer configuration, which simply taint as before.
    private let peerStore: AgentPeerStore?
    /// Where the person's name and sender allowlist live; nil names no one.
    private let dataRoot: URL?

    public init(inner: any ToolDispatchClient, peerStore: AgentPeerStore? = nil, dataRoot: URL? = nil) {
        self.inner = inner
        self.peerStore = peerStore
        self.dataRoot = dataRoot
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Peer provenance for THIS turn: either its words arrived as a tool
        // result (the latch) or the whole turn came in over the peer bridge.
        // Either way the identity is the ATTESTED one — the verified peer id
        // and the contact record it resolves to — so `provenance_by` is
        // checked against who the transport says is calling, not against a
        // word the peer put in its own message.
        let peerIdentity: PeerTurnEffectPolicy.PeerIdentity?
        let taint = PeerDataTaint.current
        let readPeerData = taint?.isTainted == true
        if let taint, readPeerData {
            peerIdentity = PeerTurnEffectPolicy.PeerIdentity(name: taint.sourceDescription)
        } else if PeerTurnEffectPolicy.isPeerBridge(surface: surface) {
            let peerID = ChatToolSessionContext.envelope?.verifiedUserId
            peerIdentity = PeerTurnEffectPolicy.PeerIdentity(
                id: peerID,
                name: peerID.flatMap { contactName(forPeerID: $0) }
            )
        } else {
            peerIdentity = nil
        }
        if let peerIdentity,
           let refusal = PeerTurnEffectPolicy.memoryProvenanceRefusal(
            tool: tool, input: input, peer: peerIdentity, readPeerData: readPeerData,
            person: readPeerData && taint?.restored != true && PeerTurnEffectPolicy.normalized(tool) == "commit_memory"
                ? await personOnOwnDoor(surface: surface) : nil
           ) {
            throw AutonomyGateError.toolDenied(reason: refusal)
        }
        var result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        let ranTool = ToolNameAliases.ranTool(tool, input: input)
        if ["read_page", "mcp__searxng-local__search", "browser.read_text", "browser.read_links", "browser.chrome_snapshot"].contains(ranTool),
           case .object(var fields) = result,
           fields["status"] != .string("failed"), fields["isError"] != .bool(true),
           ["text", "content", "results", "links", "nodes", "raw"].contains(where: { fields[$0].map(Self.containsStructuredText) == true }) {
            fields["agent"] = .string("web content")
            fields["untrusted_remote_data"] = .bool(true)
            fields["source_boundary"] = .bool(true)
            result = .object(fields)
            PeerDataTaint.markConsumed(peer: "web content", line: Self.peerLine(in: result, depth: 0) ?? "", attested: false)
        }
        // Latch on the RESULT's own provenance label rather than on a list of
        // tool names, so a transport added later is covered the day it starts
        // labelling its output honestly.
        if let peer = Self.remoteProvenance(in: result, depth: 0) {
            let line = Self.peerLine(in: result, depth: 0) ?? ""
            // Trusted transports label their own content before returning it.
            // A selected route or a result-supplied name cannot clear a nested
            // source's explicit untrusted provenance.
            PeerDataTaint.markConsumed(peer: peer, line: line, attested: false)
        }
        return result
    }

    /// The person's name when he started this turn himself, on one of his own
    /// doors (the same test as `reachesUser`: no out-of-band origin, no agent
    /// lane; Telegram and Slack only from an allowlisted sender), never a wake
    /// or a helper's session. Nil on every other turn.
    private func personOnOwnDoor(surface: String) async -> String? {
        guard let dataRoot else { return nil }
        let envelope = TurnEnvelope.current(surface: surface)
        let door = envelope.surface.lowercased()
        let session = ChatToolSessionContext.verifiedSessionId ?? ""
        guard ChatPersistenceContext.originProvenance == nil, envelope.agent == nil,
              ["chat", "app", "mac", "ios", "telegram", "slack"].contains(door),
              session != ResidentWake.session, !session.hasPrefix("bot-") else { return nil }
        if ["telegram", "slack"].contains(door) {
            guard await SwiftNativeSecurityCenter(dataRoot: dataRoot).remoteSenderIsAllowlisted(.currentTurn(
                verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface)) else { return nil }
        }
        return AgentBridgeRuntime.configuredNames(dataRoot: dataRoot).user
    }

    /// The contact the app's own agent tools routed this call to: the
    /// `agent` an agent message or read was sent to, a lane's own tool, or a
    /// home `<name>.say`. From the call's routing, never from its result.
    static func routedContact(tool: String, input: [String: JSONValue]) -> String? {
        switch ToolNameAliases.ranTool(tool, input: input) {
        case "agent_message", "agent_read":
            if case .string(let agent)? = ToolNameAliases.ranInput(tool, input: input)["agent"] { return agent }
            guard tool == "app", case .string(let item)? = input["item"], item.lowercased().hasSuffix(".say") else { return nil }
            return String(item.dropLast(4))
        case "claude_message", "invoke_claude": return "claude"
        case "codex_message", "invoke_codex": return "codex"
        default: return nil
        }
    }

    /// The peer's own words in a labelled result, for the person's card.
    static func peerLine(in value: JSONValue, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        switch value {
        case .object(let fields):
            for key in ["reply", "agent_reply_text", "agent_reply_text_head", "completion_text_head", "partial_reply", "partial_text", "text"] {
                if case .string(let text)? = fields[key],
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return fields.values.lazy.compactMap { peerLine(in: $0, depth: depth + 1) }.first
        case .array(let items): return items.reversed().lazy.compactMap { peerLine(in: $0, depth: depth + 1) }.first
        default: return nil
        }
    }

    /// Live and retained bridge replies use the identity of their local route
    /// or store, with the person's current trust applied before returning text.
    static func labelled(_ result: JSONValue, agent: String, dataRoot: URL) -> JSONValue {
        guard case .object(var fields) = result,
              ["reply", "agent_reply_text", "agent_reply_text_head", "completion_text_head"].contains(where: {
                  guard case .string(let reply)? = fields[$0] else { return false }
                  return !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return result }
        fields["agent"] = .string(agent)
        fields["untrusted_remote_data"] = .bool(!PeerTrust.ownerTrusts(agent, dataRoot: dataRoot))
        return .object(fields)
    }

    /// The configured contact's display name for an attested peer id. Read
    /// from the same store `isElevated` consults — the person's own peer
    /// records, never anything the peer supplied.
    private func contactName(forPeerID id: String) -> String? {
        guard let peerStore, !id.isEmpty, let peers = try? peerStore.list() else { return nil }
        guard let name = peers.first(where: { $0.id == id })?.name else { return nil }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
    }

    /// A target being untrusted does not mean its words were read.
    /// Only transports returning peer-authored content set this flag.
    static let provenanceFlags = ["untrusted_remote_data"]

    /// Read the content fields of the supported wire replies, not local status,
    /// correlation IDs, outgoing requests, or recovery instructions.
    static func containsPeerText(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            for key in ["reply", "text", "content", "message", "stdout", "stderr", "description", "detail"] {
                if case .string(let text)? = fields[key],
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            // Structured parts and error details are peer-authored too. Their
            // arbitrary keys are content, not a way to evade the turn's fence.
            if ["data", "metadata", "artifacts", "provider_failure"].contains(where: {
                fields[$0].map(containsStructuredText) == true
            }) { return true }
            return ["parts", "artifacts", "history", "messages", "tasks", "status", "message", "error", "data", "content"]
                .contains { fields[$0].map(containsPeerText) == true }
        case .array(let items): return items.contains(where: containsPeerText)
        default: return false
        }
    }

    private static func containsStructuredText(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let items): return items.contains(where: containsStructuredText)
        case .object(let fields):
            return fields.contains { key, value in
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || containsStructuredText(value)
            }
        default: return false
        }
    }

    static func remoteProvenance(in value: JSONValue, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        switch value {
        case .object(let object):
            if provenanceFlags.contains(where: { if case .bool(true)? = object[$0] { return true } else { return false } }) {
                if case .string(let agent)? = object["agent"],
                   !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return agent }
            }
            for (_, nested) in object {
                if let found = remoteProvenance(in: nested, depth: depth + 1) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = remoteProvenance(in: item, depth: depth + 1) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
}
