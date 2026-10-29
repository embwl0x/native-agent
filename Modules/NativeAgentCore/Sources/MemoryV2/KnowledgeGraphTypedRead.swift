// Typed reads over the checked KnowledgeGraph envelopes.
//
// The reader returns checked envelopes as JSONValue; these are the
// same projections as typed Sendable values, so app surfaces read entities,
// edges and neighbourhoods without a JSON re-serialize + Decodable pass. The
// field rules are the ones the Mac view's decoders applied: an entity field of
// the wrong shape is absent, an edge needs string endpoints and a kind (or
// `type`), and a malformed element fails the read rather than vanishing.

import Foundation
import PersistenceCore
// Blueprint: | `KnowledgeGraphTypedRead.swift` | Typed checked projections on `SwiftNativeKnowledgeGraphReader` |

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

/// `entityChecked(id:)` for a present entity.
public struct KnowledgeGraphNeighborhood: Sendable {
    public var entity: KnowledgeGraphEntity?
    public var edges: [KnowledgeGraphEdge]
    public var neighbors: [String: KnowledgeGraphEntity]
}

extension KnowledgeGraphEntity {
    init(checked value: JSONValue) throws {
        guard case .object(let o) = value else {
            throw KnowledgeGraphReadError.malformedEnvelope("entity was not an object")
        }
        id = o["id"]?.stringValue ?? ""
        name = o["name"]?.stringValue ?? ""
        type = o["type"]?.stringValue ?? ""
        firstSeen = o["first_seen"]?.stringValue
        lastSeen = o["last_seen"]?.stringValue
        mentionCount = o["mention_count"]?.exactIntegerValue
        if case .array(let raw)? = o["aliases"] {
            let strings = raw.compactMap(\.stringValue)
            aliases = strings.count == raw.count ? strings : nil
        }
        summary = o["summary"]?.stringValue
    }
}

extension KnowledgeGraphEdge {
    init(checked value: JSONValue) throws {
        guard case .object(let o) = value,
              let from = o["from"]?.stringValue,
              let to = o["to"]?.stringValue,
              let kind = o["kind"]?.stringValue ?? o["type"]?.stringValue else {
            throw KnowledgeGraphReadError.malformedEnvelope("edge needs string endpoints and a kind")
        }
        self.from = from
        self.to = to
        self.kind = kind
        weight = o["weight"]?.numberValue(coercingStrings: false, finiteOnly: false)
        mentionCount = o["mention_count"]?.exactIntegerValue
    }
}
