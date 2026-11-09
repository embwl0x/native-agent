import StandingBots
import Foundation
import NativeAgentCore
import ChatTurnContracts
import PersistenceCore
import TrustCenter

// Blueprint: | `PeerTrust.swift` | `PeerTrust` |

/// Authority follows an attested door id and the person's grant on that door.
public enum PeerTrust {
    private static let unnamedSources: Set<String> = ["another agent", "a remote peer", PeerDataTaint.unrecorded]
    /// Bind trust only after the engine installs the data-root reader; until then nothing is trusted.
    public static func install(dataRoot: URL) {
        PeerDataTaint.ownerTrusts = { ownerTrusts($0, dataRoot: dataRoot) }
        PeerDataTaint.principal = { principal($0, dataRoot: dataRoot) }
        PeerDataTaint.readTrust = { read($0, dataRoot: dataRoot) }
        CapabilityLifecycle.turnWriteCheck = { turn in
            { turn.flatMap { PeerDataTaint.abilityWriteFailure(turn: $0) } }
        }
        PeerDataTaint.sourceName = { source in
            guard !unnamedSources.contains(source) else { return nil }
            guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return nil }
            return sourceName(source, peers: peers)
        }
    }

    /// Read contacts once and each needed credential/helper once for this pass. The value contains only derived grants and names, never keys.
    /// Unreadable authority is named and grants nothing, as at the effect-time door; it is never treated as an empty successful store.
    public static func read(_ sources: [String], dataRoot: URL) -> PeerDataTaint.TrustRead {
        let peers: [AgentPeerContact]
        do { peers = try AgentPeerStore(dataRoot: dataRoot).list() }
        catch {
            nativeLog("Peer trust read: contacts unavailable (%@); no peer grant can be established", error.localizedDescription)
            return helperTrust(sources, dataRoot: dataRoot, peers: nil)
        }
        return helperTrust(sources, dataRoot: dataRoot, peers: peers)
    }

    private static func helperTrust(_ sources: [String], dataRoot: URL, peers: [AgentPeerContact]?) -> PeerDataTaint.TrustRead {
        var principals: [String: String] = [:], names: [String: String] = [:]
        var trusted = Set<String>()
        var credentials: [String: Result<String?, Error>] = [:]
        var helpers: [UUID: Bool] = [:]
        var availability: [String: Result<Bool, ToolFailureError>] = [:]
        func credential(_ id: String) throws -> String? {
            if let held = credentials[id] { return try held.get() }
            let read = Result { try AgentPeerCredentials.read(peerID: id) }
            credentials[id] = read
            return try read.get()
        }
        for source in Set(sources) {
            // Supplying the contacts to the resolver prevents another store read. A failed contact read retains the locator.
            let resolved = peers.map { principal(source, dataRoot: dataRoot, peers: $0) } ?? source.trimmingCharacters(in: .whitespacesAndNewlines)
            principals[source] = resolved
            for locator in Set([source, resolved]) {
                if let peers { names[locator] = sourceName(locator, peers: peers) }
                let value = locator.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let key = value.hasPrefix("peer:") ? String(value.dropFirst(5)) : value
                if key == "self" { trusted.insert(value); continue }
                if let id = BotDefinition.id(forSession: key.hasPrefix("bot:") ? "bot-" + key.dropFirst(4) : key) {
                    if helpers[id] == nil {
                        do {
                            helpers[id] = try helperGrant(id, dataRoot: dataRoot)
                        } catch {
                            nativeLog("Peer trust read: helper %@ unavailable (%@); no helper grant can be established",
                                      id.uuidString, error.localizedDescription)
                            helpers[id] = false
                        }
                    }
                    if helpers[id] == true { trusted.insert(value) }
                    continue
                }
                guard let peers, let peer = peers.first(where: { $0.id == key && $0.elevationAllowed }) else { continue }
                let read: Result<Bool, ToolFailureError>
                if let held = availability[peer.id] { read = held }
                else {
                    read = AgentPeerCredentials.availability(peer, peers: peers, readCredential: credential)
                    availability[peer.id] = read
                }
                switch read {
                case .success(true): trusted.insert(value)
                case .success(false): break
                case .failure(let error): nativeLog("Peer trust read: %@", error.localizedDescription)
                }
            }
        }
        return PeerDataTaint.TrustRead(principals: principals, trusted: trusted, names: names)
    }

    private static func helperGrant(_ id: UUID, dataRoot: URL) throws -> Bool {
        let data = try Data(contentsOf: dataRoot.appendingPathComponent("bots/definitions/\(id.uuidString).json"))
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let definition = document["definition"] as? [String: Any] else {
            throw ToolFailureError("Helper definition could not be decoded.", effects: .none)
        }
        return definition["deleted"] as? Bool != true
    }

    private static func sourceName(_ source: String, peers: [AgentPeerContact]) -> String? {
        guard !unnamedSources.contains(source) else { return nil }
        var key = source.lowercased()
        if key.hasPrefix("peer:") { key = String(key.dropFirst(5)) }
        if ConversationSurfaceProfile(key).isAgentBridge, key.hasSuffix("-bridge") { key = String(key.dropLast("-bridge".count)) }
        guard let door = contact(forLane: key, among: peers) ?? peers.first(where: { $0.id == key || $0.name.lowercased() == key }) else { return nil }
        return peers.first { $0.id == door.who }?.name ?? door.name
    }

    /// Only a uniquely resolved contact can become an attested peer ID; ambiguous locators carry no grant.
    public static func principal(_ source: String, dataRoot: URL, peers: [AgentPeerContact]? = nil) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = trimmed.lowercased()
        guard !key.isEmpty, !key.hasPrefix("peer:"),
              !["another agent", "a remote peer", PeerDataTaint.unrecorded].contains(key),
              let peers = peers ?? (try? AgentPeerStore(dataRoot: dataRoot).list()) else { return trimmed }
        if ConversationSurfaceProfile(key).isAgentBridge {
            if key.hasSuffix("-bridge") { key = String(key.dropLast("-bridge".count)) }
        }
        if let door = contact(forLane: key, among: peers) { return "peer:" + door.id }
        let named = peers.filter { $0.id == key || $0.name.lowercased() == key }
        return named.count == 1 ? "peer:" + named[0].id : trimmed
    }

    /// Names and handles locate a who; only an attested door id carries its grant.
    public static func ownerTrusts(_ source: String, dataRoot: URL) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = value.hasPrefix("peer:") ? String(value.dropFirst(5)) : value
        // The agent and install-local helpers need no contact-store read at the effect-time door.
        if key == "self" { return true }
        if let id = BotDefinition.id(forSession: key.hasPrefix("bot:") ? "bot-" + key.dropFirst(4) : key) {
            do { return try helperGrant(id, dataRoot: dataRoot) }
            catch {
                nativeLog("Peer trust read: helper %@ unavailable (%@); no helper grant can be established", id.uuidString, error.localizedDescription)
                return false
            }
        }
        return read([source], dataRoot: dataRoot).ownerTrusts(source)
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
