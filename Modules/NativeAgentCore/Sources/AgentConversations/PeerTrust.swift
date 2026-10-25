import Foundation
import NativeAgentCore
import ChatTurnContracts
import PersistenceCore
import TrustCenter

// Blueprint: | `PeerTrust.swift` | `PeerTrust`: installed trust reader and exact contact/principal resolution; authority follows attested doors and person grants |

/// Authority follows an attested door id and the person's grant on that door.
public enum PeerTrust {
    /// Bind `PeerDataTaint`'s trust question to this one, for this data root.
    /// The engine installs it; until then nothing is trusted.
    public static func install(dataRoot: URL) {
        PeerDataTaint.ownerTrusts = { ownerTrusts($0, dataRoot: dataRoot) }
        PeerDataTaint.principal = { principal($0, dataRoot: dataRoot) }
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

    /// The one contact a locator names, as its attested id: a peer handle
    /// stands; a lane or a contact's exact name that the address book resolves
    /// to exactly one contact becomes `peer:<id>`; anything else stands as
    /// written and so carries no grant.
    public static func principal(_ source: String, dataRoot: URL) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = trimmed.lowercased()
        guard !key.isEmpty, !key.hasPrefix("peer:"),
              !["another agent", "a remote peer", PeerDataTaint.unrecorded].contains(key),
              let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return trimmed }
        if ConversationSurfaceProfile(key).isAgentBridge {
            for suffix in ["-bridge", "_bridge"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
        }
        if let door = contact(forLane: key, among: peers) { return "peer:" + door.id }
        let named = peers.filter { $0.id == key || $0.name.lowercased() == key }
        return named.count == 1 ? "peer:" + named[0].id : trimmed
    }

    /// Names and handles locate a who; only an attested door id carries its grant.
    public static func ownerTrusts(_ source: String, dataRoot: URL) -> Bool {
        let principal = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = principal.hasPrefix("peer:") ? String(principal.dropFirst(5)) : principal
        // A helper of this install, made by the person or by her, carries the
        // person's grant: it is part of the household, not an outside agent.
        if key.hasPrefix("bot-"), let id = UUID(uuidString: String(key.dropFirst(4))) {
            let file = dataRoot.appendingPathComponent("bots/definitions/\(id.uuidString).json")
            guard let data = try? Data(contentsOf: file),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let definition = document["definition"] as? [String: Any] else { return false }
            return definition["deleted"] as? Bool != true
        }
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
