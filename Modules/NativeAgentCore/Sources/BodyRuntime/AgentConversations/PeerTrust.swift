import Foundation
import NativeAgentCore
import MindCore
import PersistenceCore
import DeskCore

// Blueprint: | `PeerTrust.swift` | `PeerTrust` |

/// Authority follows an attested door id and the person's grant on that door.
public enum PeerTrust {
    private static let unnamedSources: Set<String> = ["another agent", "a remote peer", PeerDataTaint.unrecorded]
    public static func install() {
        _ = binding
    }

    private static let binding: Void = {
        PeerDataTaint.ownerTrusts = { ownerTrusts($1, dataRoot: $0) }
        PeerDataTaint.principal = { principal($1, dataRoot: $0) }
        PeerDataTaint.readTrust = { read($1, dataRoot: $0) }
        CapabilityLifecycle.turnWriteCheck = { turn in
            { turn.flatMap { PeerDataTaint.abilityWriteFailure(turn: $0) } }
        }
        PeerDataTaint.sourceName = { dataRoot, source in
            guard !unnamedSources.contains(source) else { return nil }
            guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return nil }
            return sourceName(source, peers: peers)
        }
    }()

    /// Read contacts once and each needed credential/helper once for this pass. The value contains only derived grants and names, never keys.
    /// Unreadable authority is named and grants nothing, as at the effect-time door; it is never treated as an empty successful store.
    public static func read(_ sources: [String], dataRoot: URL, peers: [AgentPeerContact]? = nil) -> PeerDataTaint.TrustRead {
        guard !sources.isEmpty else { return PeerDataTaint.TrustRead(principals: [:], trusted: [], names: [:]) }
        let contacts: [AgentPeerContact]
        if let peers {
            contacts = peers
        } else {
            do { contacts = try AgentPeerStore(dataRoot: dataRoot).list() }
            catch {
                nativeLog("Peer trust read: contacts unavailable (%@); no peer grant can be established", error.localizedDescription)
                let principals = Dictionary(uniqueKeysWithValues: Set(sources).map { ($0, $0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                return PeerDataTaint.TrustRead(principals: principals, trusted: [], names: [:])
            }
        }
        return helperTrust(sources, dataRoot: dataRoot, peers: contacts)
    }

    public static func doorName(_ id: String, dataRoot: URL) -> String? {
        guard !id.isEmpty else { return nil }
        let peers: [AgentPeerContact]
        do { peers = try AgentPeerStore(dataRoot: dataRoot).list() }
        catch {
            nativeLog("Peer trust read: contacts unavailable (%@); door name unavailable", error.localizedDescription)
            return nil
        }
        return doorName(id, peers: peers)
    }

    private static func doorName(_ id: String, peers: [AgentPeerContact]) -> String? {
        guard !id.isEmpty, let name = peers.first(where: { $0.id == id })?.name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func helperTrust(_ sources: [String], dataRoot: URL, peers: [AgentPeerContact]) -> PeerDataTaint.TrustRead {
        var principals: [String: String] = [:], names: [String: String] = [:], doorNames: [String: String] = [:]
        var trusted = Set<String>()
        var credentials: [AgentPeerCredentials.CredentialRead]?
        var helpers: [UUID: Bool] = [:]
        var availability: [String: Result<Bool, ToolFailureError>] = [:]
        for source in Set(sources) {
            let resolved = principal(source, dataRoot: dataRoot, peers: peers)
            principals[source] = resolved
            for locator in Set([source, resolved]) {
                names[locator] = sourceName(locator, peers: peers)
                let doorID = locator.hasPrefix("peer:") ? String(locator.dropFirst(5)) : locator
                if let name = doorName(doorID, peers: peers) { doorNames[doorID] = name }
            }
            let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "self" {
                trusted.insert("self")
                continue
            }
            let value = trimmed.lowercased()
            if let id = BotDefinition.id(forSession: value.hasPrefix("bot:") ? "bot-" + value.dropFirst(4) : value) {
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
            let key = value.hasPrefix("peer:") ? String(value.dropFirst(5)) : value
            guard let peer = peers.first(where: { $0.id == key && $0.elevationAllowed }) else { continue }
            let granted: Bool
            if AgentPeerCredentials.isKeylessLocal(peer) {
                granted = true
            } else if peer.credentialKey == AgentPeerContact.credentialKey(for: peer.id) {
                let read: Result<Bool, ToolFailureError>
                if let held = availability[peer.id] { read = held }
                else {
                    let reads = credentials ?? AgentPeerCredentials.credentialReads(peers)
                    credentials = reads
                    read = AgentPeerCredentials.availability(peer, reads: reads)
                    availability[peer.id] = read
                }
                switch read {
                case .success(true): granted = true
                case .success(false): granted = false
                case .failure(let error):
                    nativeLog("Peer trust read: %@", error.localizedDescription)
                    granted = false
                }
            } else {
                granted = false
            }
            if granted {
                trusted.insert(value)
                if source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == peer.id {
                    trusted.insert(peer.id)
                }
            }
        }
        return PeerDataTaint.TrustRead(principals: principals, trusted: trusted, names: names, doorNames: doorNames)
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
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // The agent and install-local helpers need no contact-store read at the effect-time door.
        if trimmed == "self" { return true }
        let value = trimmed.lowercased()
        if let id = BotDefinition.id(forSession: value.hasPrefix("bot:") ? "bot-" + value.dropFirst(4) : value) {
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
