import Foundation
import NativeAgentCore
import ChatTurnContracts
import PersistenceCore
import TrustCenter

/// Authority follows an attested door id and the person's grant on that door.
public enum PeerTrust {
    /// Bind `PeerDataTaint`'s trust question to this one, for this data root.
    /// The engine installs it; until then nothing is trusted.
    public static func install(dataRoot: URL) {
        PeerDataTaint.ownerTrusts = { ownerTrusts($0, dataRoot: dataRoot) }
        PeerDataTaint.isAgent = { isAgent($0, dataRoot: dataRoot) }
        CapabilityLifecycle.turnWriteCheck = { PeerDataTaint.abilityWriteFailure }
        PeerDataTaint.sourceName = { source in
            guard !["another agent", "a remote peer", PeerDataTaint.unrecorded].contains(source) else { return nil }
            var key = source.lowercased()
            if key.hasPrefix("peer:") { key = String(key.dropFirst(5)) }
            if ConversationSurfaceProfile(key).isAgentBridge {
                for suffix in ["-bridge", "_bridge"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
            }
            guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return nil }
            guard let door = contact(forLane: key, among: peers) ?? peers.first(where: { $0.id == key || $0.name.lowercased() == key }) else { return nil }
            return peers.first { $0.id == door.who }?.name ?? door.name
        }
    }

    /// Whether a latch names an agent contact: a peer handle, or any contact
    /// name, id or lane the address book resolves.
    static func isAgent(_ source: String, dataRoot: URL) -> Bool {
        let key = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return false }
        if ["another agent", "a remote peer", PeerDataTaint.unrecorded].contains(key) { return true }
        if key.hasPrefix("peer:") { return true }
        if ConversationSurfaceProfile(key).isAgentBridge { return true }
        guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return false }
        return contact(forLane: key, among: peers) != nil || peers.contains { $0.id == key || $0.name.lowercased() == key }
    }

    /// Names and handles locate a who; only an attested door id carries its grant.
    public static func ownerTrusts(_ source: String, dataRoot: URL) -> Bool {
        let principal = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = principal.hasPrefix("peer:") ? String(principal.dropFirst(5)) : principal
        guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return false }
        return peers.contains { $0.id == key && $0.elevationAllowed && AgentPeerCredentials.isAvailable($0, peers: peers) }
    }

    /// A route handle belongs to exactly one who. Its doors keep their own keys and grants.
    public static func contact(forLane lane: String, among peers: [AgentPeerContact]) -> AgentPeerContact? {
        let matches = peers.filter { peer in
            (peer.who == nil || !peers.contains { $0.id == peer.who })
                && peer.handles?.contains(where: { $0.lowercased() == lane.lowercased() }) == true
        }
        return matches.count == 1 ? matches.first : nil
    }
}
