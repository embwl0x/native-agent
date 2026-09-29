// Typed reads over the checked KnowledgeGraph envelopes.
//
// The reader returns the daemon's envelope shapes as JSONValue; these are the
// same projections as typed Sendable values, so app surfaces read entities,
// edges and neighbourhoods without a JSON re-serialize + Decodable pass. The
// field rules are the ones the Mac view's decoders applied: an entity field of
// the wrong shape is absent, an edge needs string endpoints and a kind (or
// `type`), and a malformed element fails the read rather than vanishing.

import Foundation
import PersistenceCore

public struct KnowledgeGraphEntity: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var type: String
    public var firstSeen: String?
    public var lastSeen: String?
    public var mentionCount: Int?
    public var aliases: [String]?
    public var summary: String?
}

public struct KnowledgeGraphEdge: Sendable, Identifiable, Hashable {
    public var id: String { "\(from)-\(to)-\(kind)" }
    public var from: String
    public var to: String
    public var kind: String
    public var weight: Double?
    public var mentionCount: Int?
}

/// One page of `allEntitiesChecked(page:)`.
public struct KnowledgeGraphEntityPage: Sendable {
    public var entities: [KnowledgeGraphEntity]
    /// Nil when the page's edge array is missing or any edge is malformed.
    public var edges: [KnowledgeGraphEdge]?
    public var totalEntities: Int
    public var totalEdges: Int?
    public var page: Int
}

/// `entityChecked(id:)` for a present entity.
public struct KnowledgeGraphNeighborhood: Sendable {
    public var entity: KnowledgeGraphEntity?
    public var edges: [KnowledgeGraphEdge]
    public var neighbors: [String: KnowledgeGraphEntity]
}

public extension KnowledgeGraphReader {
    func entityPageChecked(page: Int) async throws -> KnowledgeGraphEntityPage {
        guard case .object(let envelope) = try await allEntitiesChecked(page: page),
              case .array(let rawEntities)? = envelope["entities"] else {
            throw KnowledgeGraphReadError.malformedEnvelope("entity page did not contain an entities array")
        }
        let entities = try rawEntities.map(KnowledgeGraphEntity.init(checked:))
        var edges: [KnowledgeGraphEdge]?
        if case .array(let rawEdges)? = envelope["edges"] {
            edges = try? rawEdges.map(KnowledgeGraphEdge.init(checked:))
        }
        return KnowledgeGraphEntityPage(
            entities: entities,
            edges: edges,
            totalEntities: envelope["total_entities"]?.typedGraphInt ?? entities.count,
            totalEdges: envelope["total_edges"]?.typedGraphInt,
            page: envelope["page"]?.typedGraphInt ?? 0
        )
    }

    /// Nil for an unknown id, kept apart from a store read error.
    func neighborhoodChecked(id: String) async throws -> KnowledgeGraphNeighborhood? {
        guard case .found(let value) = try await entityChecked(id: id) else { return nil }
        guard case .object(let envelope) = value,
              case .array(let rawEdges)? = envelope["edges"],
              case .object(let rawNeighbors)? = envelope["neighbors"] else {
            throw KnowledgeGraphReadError.malformedEnvelope("entity read did not contain edges and neighbors")
        }
        var entity: KnowledgeGraphEntity?
        if let raw = envelope["entity"], raw != .null {
            entity = try KnowledgeGraphEntity(checked: raw)
        }
        return KnowledgeGraphNeighborhood(
            entity: entity,
            edges: try rawEdges.map(KnowledgeGraphEdge.init(checked:)),
            neighbors: try rawNeighbors.mapValues(KnowledgeGraphEntity.init(checked:))
        )
    }
}

extension KnowledgeGraphEntity {
    init(checked value: JSONValue) throws {
        guard case .object(let o) = value else {
            throw KnowledgeGraphReadError.malformedEnvelope("entity was not an object")
        }
        id = o["id"]?.typedGraphString ?? ""
        name = o["name"]?.typedGraphString ?? ""
        type = o["type"]?.typedGraphString ?? ""
        firstSeen = o["first_seen"]?.typedGraphString
        lastSeen = o["last_seen"]?.typedGraphString
        mentionCount = o["mention_count"]?.typedGraphInt
        if case .array(let raw)? = o["aliases"] {
            let strings = raw.compactMap(\.typedGraphString)
            aliases = strings.count == raw.count ? strings : nil
        }
        summary = o["summary"]?.typedGraphString
    }
}

extension KnowledgeGraphEdge {
    init(checked value: JSONValue) throws {
        guard case .object(let o) = value,
              let from = o["from"]?.typedGraphString,
              let to = o["to"]?.typedGraphString,
              let kind = o["kind"]?.typedGraphString ?? o["type"]?.typedGraphString else {
            throw KnowledgeGraphReadError.malformedEnvelope("edge needs string endpoints and a kind")
        }
        self.from = from
        self.to = to
        self.kind = kind
        switch o["weight"] {
        case .double(let d)?: weight = d
        case .int(let i)?: weight = Double(i)
        default: weight = nil
        }
        mentionCount = o["mention_count"]?.typedGraphInt
    }
}

private extension JSONValue {
    var typedGraphString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var typedGraphInt: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return Int(exactly: d)
        default: return nil
        }
    }
}
