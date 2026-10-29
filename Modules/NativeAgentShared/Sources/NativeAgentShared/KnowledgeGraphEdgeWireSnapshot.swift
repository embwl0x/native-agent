import Foundation

// Blueprint: | `KnowledgeGraphEdgeWireSnapshot.swift` | `KnowledgeGraphEdgeWireSnapshot`: shared immutable edge decoding; platform wrappers retain UI identity and extra fields |

public let knowledgeGraphTypeSymbols: [String: String] = [
    "person": "person.circle",
    "organization": "building.2",
    "project": "folder",
    "concept": "lightbulb",
    "place": "mappin.circle",
    "event": "calendar",
    "tool": "wrench.and.screwdriver",
    "fact": "text.quote",
]

/// Common edge snapshot decoding; platform presentation supplies UI identity.
public struct KnowledgeGraphEdgeWireSnapshot: Decodable, Equatable, Sendable {
    public let from: String
    public let to: String
    public let kind: String
    public let weight: Double?

    private enum CodingKeys: String, CodingKey {
        case from, to, kind, type, weight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        if let decodedKind = try? container.decode(String.self, forKey: .kind) {
            kind = decodedKind
        } else {
            kind = try container.decode(String.self, forKey: .type)
        }
        weight = try? container.decode(Double.self, forKey: .weight)
    }
}
