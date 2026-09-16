import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// TASK-LOCAL PROVENANCE FOR A PEER'S WORDS.
///
/// `agent_message` / `agent_read` already label their result
/// `untrusted_remote_data: true` — but that label rode back into the ordinary
/// tool loop as prose, where the model is free to act on it. A remote agent's
/// reply is DATA, and the one thing data must never be is the authority for
/// the next tool call.
///
/// So the label is bound to the TURN instead of to a string. The moment a turn
/// consumes a peer result, this box latches; from then until the turn ends,
/// `PeerDataTaintDispatcher` refuses the effect classes a peer could otherwise
/// have talked the model into: local effects, durable memory/persona writes,
/// disclosure reads, and external sends. The refusal says why, so the model
/// relays the peer's request to the person instead of executing it.
///
/// The scope is exactly one turn: a task-local reference box, latched at most
/// once, discarded when the turn's task tree ends. That IS the "until the next
/// authenticated human turn" boundary — the next turn starts with a fresh box.
public final class PeerDataTaint: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []

    public init() {}

    @TaskLocal public static var current: PeerDataTaint?

    /// Run `operation` under a fresh taint scope, unless one is already bound
    /// (a nested loop must not silently launder its parent's taint).
    public static func withScope<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        if current != nil { return try await operation() }
        return try await $current.withValue(PeerDataTaint(), operation: operation, isolation: isolation)
    }

    /// Latch: this turn has now read a remote peer's words.
    public static func markConsumed(peer: String) {
        current?.mark(peer: peer)
    }

    func mark(peer: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "a remote peer" : trimmed
        guard !sources.contains(name), sources.count < 8 else { return }
        sources.append(name)
    }

    public var isTainted: Bool {
        lock.lock(); defer { lock.unlock() }
        return !sources.isEmpty
    }

    public var sourceDescription: String {
        lock.lock(); defer { lock.unlock() }
        return sources.joined(separator: ", ")
    }
}


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

    public init(inner: any ToolDispatchClient, peerStore: AgentPeerStore? = nil) {
        self.inner = inner
        self.peerStore = peerStore
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Peer provenance for THIS turn: either its words arrived as a tool
        // result (the latch) or the whole turn came in over the peer bridge.
        // Either way the identity is the ATTESTED one — the verified peer id
        // and the contact record it resolves to — so `provenance_by` is
        // checked against who the transport says is calling, not against a
        // word the peer put in its own message.
        let peerIdentity: PeerTurnEffectPolicy.PeerIdentity?
        if let taint = PeerDataTaint.current, taint.isTainted {
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
            tool: tool, input: input, peer: peerIdentity
           ) {
            throw AutonomyGateError.toolDenied(reason: refusal)
        }
        let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        // Latch on the RESULT's own provenance label rather than on a list of
        // tool names, so a transport added later is covered the day it starts
        // labelling its output honestly.
        if let peer = Self.remoteProvenance(in: result, depth: 0), !isElevated(peer) {
            PeerDataTaint.markConsumed(peer: peer)
        }
        return result
    }

    /// Agent, 2026-09-15: peer text cannot grant authority, but the person's
    /// EXISTING authorization still counts — a collaboration he set up in
    /// Trust → Connected agents should not make him re-approve every routine
    /// step. So a result from a peer he elevated does not taint the turn.
    ///
    /// Keyed on the peer RECORD behind the result's `peer:<id>` provenance,
    /// never on anything the peer wrote: the handle is minted by
    /// `SwiftToolDispatcher+AgentCommunication` from the configured contact
    /// the caller asked for, `allowElevation` has exactly one writer
    /// (`AgentPeerStore.setElevation`, Trust Center only), and anything that
    /// is not an exact configured id — including the anonymous "a remote
    /// peer" label — falls through to tainting.
    private func isElevated(_ provenance: String) -> Bool {
        guard let peerStore, provenance.hasPrefix("peer:") else { return false }
        let id = String(provenance.dropFirst("peer:".count))
        guard !id.isEmpty, let peers = try? peerStore.list() else { return false }
        return peers.first(where: { $0.id == id })?.elevationAllowed == true
    }

    /// The configured contact's display name for an attested peer id. Read
    /// from the same store `isElevated` consults — the person's own peer
    /// records, never anything the peer supplied.
    private func contactName(forPeerID id: String) -> String? {
        guard let peerStore, !id.isEmpty, let peers = try? peerStore.list() else { return nil }
        guard let name = peers.first(where: { $0.id == id })?.name else { return nil }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
    }

    /// The provenance labels a peer-carrying result is required to set —
    /// `untrusted_remote_data` on the network transports
    /// (SwiftToolDispatcher+AgentCommunication) and `target_is_untrusted_data`
    /// on the desktop route's plan and its projection.
    static let provenanceFlags = ["untrusted_remote_data", "target_is_untrusted_data"]

    static func remoteProvenance(in value: JSONValue, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        switch value {
        case .object(let object):
            if provenanceFlags.contains(where: { if case .bool(true)? = object[$0] { return true } else { return false } }) {
                if case .string(let agent)? = object["agent"] { return agent }
                return "a remote peer"
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

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
}
