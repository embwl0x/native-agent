import Foundation
import NativeAgentCore
import ChatTurnContracts
import PersistenceCore

/// TRUSTED PEERS (User, 10-03): "stuff coming from you or codex shouldnt
/// require approvals", then "any of those switches for the agents being turned
/// on should kill any approvals needed for anything coming from the agent too".
///
/// A peer the person elevated in Trust → Connected agents is the person's own:
/// its turn, and its words in a turn, steer nothing a peer steers, at every
/// Trust level. What applies to her own turn at that level still applies;
/// nothing peer-specific is added. This is the one question every taint
/// source asks (`PeerDataTaint.mark` / `markElevated`, for identities this app
/// attested), so the floor, skill
/// origin, MY QUEUE, the wake and the desk latches all follow it. A peer he
/// has not elevated is unchanged. No setting of its own: the grant is his
/// elevation switch.
public enum PeerTrust {
    /// Bind `PeerDataTaint`'s trust question to this one, for this data root.
    /// The engine installs it; until then nothing is trusted.
    public static func install(dataRoot: URL) {
        PeerDataTaint.ownerTrusts = { ownerTrusts($0, dataRoot: dataRoot) }
        PeerDataTaint.isAgent = { isAgent($0, dataRoot: dataRoot) }
        CapabilityLifecycle.turnWriteCheck = { PeerDataTaint.abilityWriteCheck }
    }

    /// Whether a latch names an agent contact: a peer handle, or any contact
    /// name, id or lane the address book resolves.
    static func isAgent(_ source: String, dataRoot: URL) -> Bool {
        var key = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key == "a remote peer" { return false }
        if key == "another agent" { return true } // an unidentified bridge peer stays untrusted
        if key.hasPrefix("peer:") { return true }
        for suffix in ["-bridge", "_bridge"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
        if laneHosts[key] != nil { return true }
        guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return false }
        return peers.contains { $0.id == key || $0.name.lowercased() == key }
    }

    /// Whether the steer `source` is the person's own: a contact (`peer:<id>`
    /// or its bare id or display name) he elevated, or a built-in lane (`claude`, `codex`,
    /// their bridge spellings) whose own contact he elevated. Read fresh
    /// through the address book's own validated reader: an address book that
    /// does not read or validate trusts no one. Anything else is a peer.
    public static func ownerTrusts(_ source: String, dataRoot: URL) -> Bool {
        let principal = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var key = principal
        for suffix in ["-bridge", "_bridge"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
        if key.hasPrefix("peer:") { key = String(key.dropFirst(5)) }
        let hosts = laneHosts[key]
        guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return false }
        if hosts != nil { return contact(forLane: key, among: peers)?.elevationAllowed == true }
        if UUID(uuidString: key) != nil || principal.hasPrefix("peer:") {
            return peers.contains { $0.id == key && $0.elevationAllowed }
        }
        return peers.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == principal }?.elevationAllowed == true
    }

    /// Named bridge bearers bind to the same contact that supplies lane trust.
    public static func contact(forLane lane: String, among peers: [AgentPeerContact]) -> AgentPeerContact? {
        guard let hosts = laneHosts[lane] else { return nil }
        return peers.filter {
            ["mcp", "acp"].contains($0.endpoint.scheme ?? "") && hosts.contains($0.endpoint.host ?? "")
        }.sorted {
            if $0.elevationAllowed != $1.elevationAllowed { return $0.elevationAllowed }
            return $0.id < $1.id
        }.first
    }

    /// The built-in lanes and the hosts their contacts connect through, as
    /// `AgentContactIdentity` already unifies them: Claude reaches her over
    /// Claude Code and Claude Desktop, Codex over its CLI.
    static let laneHosts: [String: Set<String>] = [
        "claude": ["claude-code", "claude-desktop"],
        "codex": ["codex", "codex-cli"],
    ]
}
