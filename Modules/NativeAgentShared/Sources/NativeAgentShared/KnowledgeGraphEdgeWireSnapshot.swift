import Foundation

/// Common edge snapshot decoding; platform wrappers retain UI identity and extra fields.
public struct KnowledgeGraphEdgeWireSnapshot: Decodable {
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
