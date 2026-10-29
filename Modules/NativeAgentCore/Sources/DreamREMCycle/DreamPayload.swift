import Foundation
// Blueprint: | `DreamPayload.swift` | `DreamPayload` and `DreamClaim`: the dream's per-claim gentleness and owner-relevance judgments travel with its admitted quote/source provenance; older claims remain unknown for Reach |

/// Meaning judged by the dream that produced the claim, never by a lexical
/// filter in a later reader. Nil is unknown and grants no outreach eligibility.
public struct DreamClaim: Sendable, Codable {
    public var provenance: DreamEntryProvenance
    public var gentle: Bool?
    public var aboutOwner: Bool?

    private enum CodingKeys: String, CodingKey { case gentle; case aboutOwner = "about_owner" }

    public init(from decoder: Decoder) throws {
        provenance = try DreamEntryProvenance(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gentle = try container.decodeIfPresent(Bool.self, forKey: .gentle)
        aboutOwner = try container.decodeIfPresent(Bool.self, forKey: .aboutOwner)
    }

    public func encode(to encoder: Encoder) throws {
        try provenance.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gentle, forKey: .gentle)
        try container.encode(aboutOwner, forKey: .aboutOwner)
    }

    /// Older claims retain unknown judgments; only trailing section blocks count.
    public static func read(in content: String) -> [Self] {
        DreamEntryProvenance.readClaims(in: content, as: Self.self)
    }
}

struct DreamPayload: Decodable {
    let title: String
    let summary: String
    let mood: String
    let affect: Double?
    let emergingThemes: [String]
    let surprisingMoments: [String]
    let claims: [DreamClaim]
    /// Optional `settled: <key>: <how>` / `let go: <key>` lines about her open cares.
    let cares: [String]

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case mood
        case affect
        case emergingThemes = "emerging_themes"
        case surprisingMoments = "surprising_moments"
        case claims
        case cares
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        mood = try container.decode(String.self, forKey: .mood)
        affect = try container.decode(Double?.self, forKey: .affect)
        if let affect, !affect.isFinite || !(-1...1).contains(affect) {
            throw DecodingError.dataCorruptedError(forKey: .affect, in: container,
                debugDescription: "affect must be null or a number from -1 to 1")
        }
        emergingThemes = try container.decode([String].self, forKey: .emergingThemes)
        surprisingMoments = try container.decode([String].self, forKey: .surprisingMoments)
        claims = try container.decode([DreamClaim].self, forKey: .claims)
        cares = try container.decodeIfPresent([String].self, forKey: .cares) ?? []

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "title must not be blank"
            )
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .summary,
                in: container,
                debugDescription: "summary must not be blank"
            )
        }
        guard !mood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .mood,
                in: container,
                debugDescription: "mood must not be blank"
            )
        }
    }
}
