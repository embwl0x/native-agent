import MindCore
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
// Blueprint: | `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher`: live peer approval and per-teller memory provenance |

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

    static func commitTellers(_ input: [String: JSONValue], turn: Turn) throws -> [String]? {
        try memoryTellers("commit_memory", input: input, surface: turn.envelope?.surface ?? "", turn: turn)
    }

    static func memoryTellers(_ tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                              rewriteChangesText: Bool? = nil) throws -> [String]? {
        guard PeerTurnEffectPolicy.judgesProvenance(tool: tool, input: input) else { return nil }
        let through = MemoryDataProvenance.through(turn: turn)
        let bridge = PeerTurnEffectPolicy.isPeerBridge(surface: surface)
        if through.isEmpty, !bridge {
            return try PeerTurnEffectPolicy.memoryTellers(tool: tool, input: input, peers: [], readPeerData: false)
        }
        let trust = PeerTrust.read(through + PeerDataTaint.trustedTurnCandidates(turn), dataRoot: turn.dataRoot)
        let steering = MemoryDataProvenance.steering(through, trust: trust)
        var peers = steering.map { source -> PeerTurnEffectPolicy.PeerIdentity in
            guard source.hasPrefix("peer:"), source.count > 5 else { return .init(name: source) }
            let id = String(source.dropFirst(5))
            return .init(id: id, name: trust.doorName(id))
        }
        if peers.isEmpty, bridge, !PeerDataTaint.trustedTurn(turn, trust: { trust }) {
            peers = [.init()]
        }
        return try PeerTurnEffectPolicy.memoryTellers(tool: tool, input: input, peers: peers,
            readPeerData: turn.peerSteering?.isTainted(trust: { trust }) == true, rewriteChangesText: rewriteChangesText)
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
        let ran = ToolNameAliases.ranCall(tool, input: input)
        _ = try PeerDataTaintDispatcher.memoryTellers(tool, input: input, surface: surface, turn: turn, rewriteChangesText: false)
        var result = try await admitEffect(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        if ["read_page", "web_search", "browser.read_text", "browser.read_links", "browser.chrome_snapshot"].contains(ran.tool),
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
