import MindCore
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
// Blueprint: | `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher`, `peerApproval`: Read trust live; reads attribute, never steer. |

public enum PeerDataTaintDispatcher {
    static func trustSources(turn: Turn) -> [String] {
        var sources = turn.peerSteering?.checkpointSources ?? []
        for candidate in PeerDataTaint.trustedTurnCandidates(turn) where !sources.contains(candidate) {
            sources.append(candidate)
        }
        return sources
    }

    /// Preview and execution read the same live trust and peer approval floor.
    public static func peerApproval(turn: Turn, surface: String, protectedAction: Bool,
                                    peerName: String? = nil) -> (requester: String?, required: Bool) {
        var held: PeerDataTaint.TrustRead?
        let trust: () -> PeerDataTaint.TrustRead = {
            if let held { return held }
            let read = PeerTrust.read(trustSources(turn: turn), dataRoot: turn.dataRoot)
            held = read
            return read
        }
        return peerApproval(turn: turn, surface: surface, protectedAction: protectedAction, peerName: peerName, trust: trust)
    }

    static func peerApproval(turn: Turn, surface: String, protectedAction: Bool,
                             peerName: String? = nil, trust: () -> PeerDataTaint.TrustRead) -> (requester: String?, required: Bool) {
        let taint = turn.peerSteering
        let tainted = taint?.isTainted(trust: trust) == true
        let answered = !(taint?.elevatedSources ?? []).isEmpty && !tainted
        let peerID = PeerDataTaint.attestedPeerID(turn: turn)
        let requester: String?
        if answered || (!tainted && PeerDataTaint.trustedTurn(turn, trust: trust)) {
            requester = nil
        } else {
            let resolvedName = peerName ?? (PeerTurnEffectPolicy.isPeerBridge(surface: surface)
                ? peerID.flatMap { trust().doorName($0) } : nil)
            requester = PeerTurnEffectPolicy.peerRequester(
                surface: surface, peerID: peerID, peerName: resolvedName,
                taintSource: tainted ? taint?.sourceDescription(trust: trust) : nil)
        }
        return (requester, requester != nil && protectedAction)
    }

    /// The refusal for a memory call whose telling is not by the door that started the turn. That door is read from the turn's peer sources and the
    /// person's contact record, never a word the peer put in its message; a trusted door, or a turn no peer started, has none.
    static func provenanceRefusal(tool: String, input: [String: JSONValue], surface: String, turn: Turn, peerStore: AgentPeerStore?) -> String? {
        guard PeerTurnEffectPolicy.judgesProvenance(tool: tool, input: input) else { return nil }
        let peerIdentity: PeerTurnEffectPolicy.PeerIdentity
        let taint = turn.peerSteering
        let root = peerStore?.dataRoot ?? turn.dataRoot
        var held: PeerDataTaint.TrustRead?
        let trust: () -> PeerDataTaint.TrustRead = {
            if let held { return held }
            let read = PeerTrust.read(trustSources(turn: turn), dataRoot: root)
            held = read
            return read
        }
        let readPeerData = taint?.isTainted(trust: trust) == true
        if let taint, readPeerData {
            let steering = taint.untrustedSources(trust: trust)
            if steering.count == 1, steering[0].hasPrefix("peer:") {
                let doorID = String(steering[0].dropFirst(5))
                peerIdentity = PeerTurnEffectPolicy.PeerIdentity(
                    id: doorID,
                    name: peerStore == nil ? nil : trust().doorName(doorID)
                )
            } else {
                peerIdentity = PeerTurnEffectPolicy.PeerIdentity(
                    name: steering.map { source in
                        guard source.hasPrefix("peer:") else { return source }
                        let doorID = String(source.dropFirst(5))
                        return (peerStore == nil ? nil : trust().doorName(doorID)) ?? source
                    }.joined(separator: ", ")
                )
            }
        } else if PeerTurnEffectPolicy.isPeerBridge(surface: surface), !PeerDataTaint.trustedTurn(turn, trust: trust) {
            let peerID = PeerDataTaint.attestedPeerID(turn: turn)
            peerIdentity = PeerTurnEffectPolicy.PeerIdentity(
                id: peerID,
                name: peerID.flatMap { peerStore == nil ? nil : trust().doorName($0) }
            )
        } else {
            return nil
        }
        return PeerTurnEffectPolicy.provenanceRefusal(tool: tool, input: input, peer: peerIdentity, readPeerData: readPeerData)
    }

    /// The contact the app's own agent tools routed this call to: the `agent` an agent message or read was sent to, or a home `<name>.say`.
    /// From the call's routing, never from its result.
    static func routedContact(tool: String, input: [String: JSONValue]) -> String? {
        switch ToolNameAliases.ranTool(tool, input: input) {
        case "agent_message", "agent_read":
            if case .string(let agent)? = ToolNameAliases.ranInput(tool, input: input)["agent"] { return agent }
            guard tool == "app", case .string(let item)? = input["item"], item.lowercased().hasSuffix(".say") else { return nil }
            return String(item.dropLast(4))
        default: return nil
        }
    }

    /// A lane's reply, a run the agent just made or one its ledger or saved wakeup cached: the app wrote it from the route it ran on, so it is stamped with
    /// that route (`agent`: the contact's door, or the lane) and read under that stamp. A trusted route never steers.
    static func labelled(_ result: JSONValue, agent: String, dataRoot: URL) -> JSONValue {
        guard case .object(var fields) = result,
              let reply = ["reply", "agent_reply_text", "agent_reply_text_head", "completion_text_head"].lazy.compactMap({ key -> String? in
                  guard case .string(let reply)? = fields[key], !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                  return reply
              }).first else { return result }
        fields["agent"] = .string(agent)
        let speakers = ContactThread.Line(text: reply, stamp: .init(source: agent.isEmpty ? nil : agent, steeredBy: [], contact: true)).speakers
        let trust = PeerTrust.read(speakers, dataRoot: dataRoot)
        fields["untrusted_remote_data"] = .bool(!speakers.allSatisfy { trust.ownerTrusts(trust.principal($0)) })
        return .object(fields)
    }

    /// A target being untrusted does not mean its words were read. Only transports returning peer-authored content set this flag.
    static let provenanceFlags = ["untrusted_remote_data"]

    /// Read the content fields of the supported wire replies, not local status, correlation IDs, outgoing requests, or recovery instructions.
    static func containsPeerText(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            for key in ["reply", "text", "content", "message", "stdout", "stderr", "description", "detail"] {
                if case .string(let text)? = fields[key],
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            // Structured parts and error details are peer-authored too. Their arbitrary keys are content, not a way to evade the turn's fence.
            if ["data", "metadata", "artifacts", "provider_failure"].contains(where: {
                fields[$0].map(containsStructuredText) == true
            }) { return true }
            return ["parts", "artifacts", "history", "messages", "tasks", "status", "message", "error", "data", "content"]
                .contains { fields[$0].map(containsPeerText) == true }
        case .array(let items): return items.contains(where: containsPeerText)
        default: return false
        }
    }

    fileprivate static func containsStructuredText(_ value: JSONValue) -> Bool {
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

    /// Every source a labelled tool receipt names, for history's attribution: the attested door, each flagged object's agent, and the `steered_by` a line
    /// recorded. Display only: recorded steering is provenance the history hit shows, never a speaker the turn latches.
    static func remoteProvenances(in value: JSONValue) -> [String] {
        var found: [String] = []
        func add(_ peer: String) {
            let peer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !peer.isEmpty, !found.contains(peer) { found.append(peer) }
        }
        if case .object(let top) = value, let attested = attestedPeerID(top), carriesProvenanceFlag(value, depth: 0) { add(attested) }
        func walk(_ value: JSONValue, depth: Int) {
            guard depth < 6 else { return }
            switch value {
            case .object(let object):
                if provenanceFlags.contains(where: { if case .bool(true)? = object[$0] { return true } else { return false } }) {
                    if let attested = attestedPeerID(object) { add(attested) }
                    else if case .string(let agent)? = object["agent"] { add(agent) }
                    if case .array(let steering)? = object["steered_by"] {
                        for case .string(let peer) in steering { add(peer) }
                    }
                }
                for (_, nested) in object { walk(nested, depth: depth + 1) }
            case .array(let items): for item in items { walk(item, depth: depth + 1) }
            default: return
            }
        }
        walk(value, depth: 0)
        return found
    }

    private static func attestedPeerID(_ object: [String: JSONValue]) -> String? {
        for key in ["agent_id", "agent"] {
            if case .string(let id)? = object[key], id.hasPrefix("peer:") { return id }
        }
        return nil
    }

    private static func carriesProvenanceFlag(_ value: JSONValue, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        switch value {
        case .object(let object):
            if provenanceFlags.contains(where: { if case .bool(true)? = object[$0] { return true } else { return false } }) { return true }
            return object.values.contains { carriesProvenanceFlag($0, depth: depth + 1) }
        case .array(let items):
            return items.contains { carriesProvenanceFlag($0, depth: depth + 1) }
        default:
            return false
        }
    }

}

extension DoorPipeline {
    func checkProvenance(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        // Peer provenance comes from the turn's origin, never a read. Check provenance_by against the transport-attested peer and its contact record, never a
        // word the peer put in its message.
        if let refusal = PeerDataTaintDispatcher.provenanceRefusal(tool: tool, input: input, surface: surface, turn: turn, peerStore: AgentPeerStore(dataRoot: dataRoot)) {
            throw AutonomyGateError.toolDenied(reason: refusal)
        }
        var result = try await admitEffect(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        let ranTool = ToolNameAliases.ranTool(tool, input: input)
        if ["read_page", "web_search", "browser.read_text", "browser.read_links", "browser.chrome_snapshot"].contains(ranTool),
           case .object(var fields) = result,
           ["text", "content", "results", "links", "nodes", "raw"].contains(where: { fields[$0].map(PeerDataTaintDispatcher.containsStructuredText) == true }) {
            fields["agent"] = .string("web content")
            fields["untrusted_remote_data"] = .bool(true)
            fields["source_boundary"] = .bool(true)
            result = .object(fields)
        }
        return result
    }
}
