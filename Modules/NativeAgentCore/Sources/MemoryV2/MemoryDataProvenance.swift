import ChatTurnContracts
import Foundation
import PersistenceCore

/// Stored untrusted content keeps its steer through duplicate saves and edits.
/// Reading remains allowed; only subsequent effects use the turn's usual gates.
public enum MemoryDataProvenance {
    public static func sources(in metadata: JSONValue?, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [String] {
        guard case .object(let fields)? = metadata else { return [] }
        var sources: [String] = []
        for key in ["peer_sources", "peer_data_sources", "untrusted_sources"] {
            guard case .array(let values)? = fields[key] else { continue }
            for case .string(let source) in values where !source.isEmpty && !sources.contains(source) {
                sources.append(source)
            }
        }
        // An explicit empty checkpoint attests a clean write. Only older rows
        // need their descriptive told provenance interpreted as a boundary.
        if fields["peer_sources"] == nil, fields["provenance"] == .string("told"),
           case .string(let by)? = fields["provenance_by"], !by.isEmpty,
           by.caseInsensitiveCompare(MemoryRecallQueryExpansion.names(
            storeDirectory: dataRoot.appendingPathComponent("memory")).user ?? "the user") != .orderedSame,
           !sources.contains(by) { sources.append(by) }
        if sources.isEmpty, fields["untrusted_remote_data"] == .bool(true) {
            sources.append("untrusted stored content")
        }
        return Array(sources.prefix(8))
    }

    public static func fields(in metadata: JSONValue?, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [String: JSONValue] {
        let sources = sources(in: metadata, dataRoot: dataRoot)
        if sources.isEmpty {
            if case .object(let fields)? = metadata, case .array? = fields["peer_sources"] {
                return ["peer_sources": .array([])]
            }
            return [:]
        }
        return ["untrusted_remote_data": .bool(true), "peer_sources": .array(sources.map(JSONValue.string)),
                "agent": .string(sources.joined(separator: ", ")), "source_boundary": .bool(true)]
    }

    static func merging(existing: JSONValue?, incoming: JSONValue?) -> [String: JSONValue] {
        var sources = sources(in: existing)
        for source in self.sources(in: incoming) where !sources.contains(source) {
            if sources.count < 8 { sources.append(source) }
        }
        return fields(in: .object(["peer_sources": .array(sources.map(JSONValue.string))]))
    }

    public static func preserving(existing: JSONValue?, incoming: JSONValue?) -> JSONValue? {
        let provenance = merging(existing: existing, incoming: incoming)
        guard !provenance.isEmpty else { return incoming }
        var fields: [String: JSONValue] = [:]
        if case .object(let value)? = incoming { fields = value }
        fields.merge(provenance) { _, value in value }
        return .object(fields)
    }

    public static func stamping(_ metadata: JSONValue?) -> JSONValue? {
        var sources = PeerDataTaint.current?.checkpointSources ?? []
        if ChatToolSessionContext.envelope?.surface.lowercased().replacingOccurrences(of: "_", with: "-") == "agent-bridge" {
            let id = ChatToolSessionContext.envelope?.verifiedUserId
            let peer = id.map { "peer:" + $0 } ?? "another agent"
            if (id == nil || !PeerDataTaint.ownerTrusts(peer)), !sources.contains(peer) { sources.append(peer) }
        }
        var fields: [String: JSONValue] = [:]
        if case .object(let value)? = metadata { fields = value }
        if fields["peer_sources"] == nil { fields["peer_sources"] = .array([]) }
        let provenance = merging(existing: .object(fields), incoming: .object([
            "peer_sources": .array(sources.map(JSONValue.string))
        ]))
        fields["peer_sources"] = .array(sources.map(JSONValue.string))
        fields.merge(provenance) { _, value in value }
        return .object(fields)
    }

    public static func consume(_ metadata: JSONValue?, dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        // Recorded taint cannot be cleared by a later elevation of its source.
        for source in sources(in: metadata, dataRoot: dataRoot) { PeerDataTaint.markConsumed(peer: source, attested: false) }
    }
}
