import Foundation

// ---------------------------------------------------------------------------
// MARK: - Models
// ---------------------------------------------------------------------------

// Dual-shape decoder.
// Canonical checked reader envelope:
// {entities: [...], edges: [...], total_entities, total_edges?, page?}.
// The dict-shaped legacy JSON decoder remains for pre-SQLite fixtures only.
// Either way `entities: [KGEntity]` is what the SwiftUI view iterates over.
struct KGEntityResponse: Decodable {
    var entities: [KGEntity]
    var edges: [KGEdge]?
    var totalEntities: Int
    var totalEdges: Int?
    var page: Int

    private enum CodingKeys: String, CodingKey {
        case entities, edges, page
        case totalEntities = "total_entities"
        case totalEdges = "total_edges"
        case commitSeq = "_commit_seq"
        case version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Canonical dict shape first.
        if let dict = try? container.decode([String: KGEntity].self, forKey: .entities) {
            entities = dict.map { (key, value) -> KGEntity in
                var e = value
                if e.id.isEmpty { e.id = key }
                return e
            }
            entities.sort { lhs, rhs in
                if lhs.name == rhs.name { return lhs.id < rhs.id }
                return lhs.name < rhs.name
            }
            edges = try? container.decode([KGEdge].self, forKey: .edges)
            totalEntities = entities.count
            totalEdges = edges?.count
            page = 0
            return
        }

        // Legacy envelope fallback.
        entities = try container.decode([KGEntity].self, forKey: .entities)
        edges = try? container.decode([KGEdge].self, forKey: .edges)
        if let t = try? container.decode(Int.self, forKey: .totalEntities) {
            totalEntities = t
        } else {
            totalEntities = entities.count
        }
        totalEdges = try? container.decode(Int.self, forKey: .totalEdges)
        page = (try? container.decode(Int.self, forKey: .page)) ?? 0
    }
}

struct KGEntity: Decodable, Identifiable {
    var id: String
    var name: String
    var type: String
    var first_seen: String?
    var last_seen: String?
    var mention_count: Int?
    var aliases: [String]?
    var summary: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, aliases, summary
        case first_seen
        case last_seen
        case mention_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` may be absent on the value in the dict shape — caller fills it
        // from the dict key. Default to empty so the decode doesn't fail.
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        first_seen = try? c.decode(String.self, forKey: .first_seen)
        last_seen = try? c.decode(String.self, forKey: .last_seen)
        mention_count = try? c.decode(Int.self, forKey: .mention_count)
        aliases = try? c.decode([String].self, forKey: .aliases)
        summary = try? c.decode(String.self, forKey: .summary)
    }
}

struct KGNeighborsResponse: Decodable {
    var entity: KGEntity?
    var edges: [KGEdge]
    var neighbors: [String: KGEntity]
}

struct KGEdge: Decodable, Identifiable {
    var id: String { "\(from)-\(to)-\(kind)" }
    var from: String
    var to: String
    var kind: String
    var weight: Double?
    var mention_count: Int?

    private enum CodingKeys: String, CodingKey {
        case from, to, kind, type, weight, mention_count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        if let decodedKind = try? container.decode(String.self, forKey: .kind) {
            kind = decodedKind
        } else {
            kind = try container.decode(String.self, forKey: .type)
        }
        weight = try? container.decode(Double.self, forKey: .weight)
        mention_count = try? container.decode(Int.self, forKey: .mention_count)
    }
}

struct KGSearchResponse: Decodable {
    var results: [KGEntity]
}
