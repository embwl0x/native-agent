import Foundation
import PersistenceCore
import MindCore
// Blueprint: | `DreamPayload.swift` | `DreamPayload`, `DreamClaim`, `DreamLesson`. |

struct DreamLesson: Sendable, Codable {
    let lesson: String
    let from: String
    let kind: String

    var diaryLine: String { "- \(lesson) (from: \(from))\n" }

    init?(_ value: JSONValue) {
        guard let fields = value.objectValue,
              let lesson = fields["lesson"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let from = fields["from"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let kind = fields["kind"]?.stringValue,
              !lesson.isEmpty, lesson.count <= 500, !from.isEmpty, from.count <= 500,
              ["how", "fact"].contains(kind) else { return nil }
        self.lesson = lesson
        self.from = from
        self.kind = kind
    }
}

/// Use the dream's own judgment rather than later lexical inference; unknown judgment grants no outreach eligibility.
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

    /// Absent judgments remain unknown; only trailing section blocks establish them.
    public static func read(in content: String) -> [DreamClaimSection<Self>] {
        DreamEntryProvenance.readClaims(in: content, as: Self.self)
    }
}

struct DreamPayload: Decodable, Sendable {
    typealias Drops = (total: Int, mergesMalformed: Int)
    let title: String
    let summary: String
    let mood: String
    let affect: Double?
    let emergingThemes: [String]
    let surprisingMoments: [String]
    let claims: [DreamClaim]
    let cares: [String]
    let lessons: [DreamLesson]
    let careMerges: [CognitiveCareMerge]
    let careStanceChanges: [CognitiveCareStanceChange]
    private(set) var traits: [CognitiveSelfKnowledge.Trait]
    private(set) var story: [CognitiveSelfKnowledge.Story]
    private(set) var people: [CognitiveSelfKnowledge.Person]
    let retainedFields: [String: JSONValue]
    var drops: Drops

    mutating func bindSelfReading(to night: CognitiveCareNight) {
        let proposed = traits.count + story.count + people.count
        traits.removeAll { !$0.shownBy.allSatisfy(night.selfStoryRefs.contains) }
        story.removeAll { !$0.shownBy.allSatisfy(night.selfChangeRefs.contains) }
        people.removeAll { !night.selfPeople.contains($0.person) }
        drops.total += proposed - (traits.count + story.count + people.count)
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case mood
        case affect
        case emergingThemes = "emerging_themes"
        case surprisingMoments = "surprising_moments"
        case claims
        case cares
        case lessons
        case careMerges = "merge"
        case careStanceChanges = "stance_changes"
        case traits, story, people
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        mood = try container.decode(String.self, forKey: .mood)
        affect = try container.decodeIfPresent(Double.self, forKey: .affect)
        if let affect, !affect.isFinite || !(-1...1).contains(affect) {
            throw DecodingError.dataCorruptedError(forKey: .affect, in: container,
                debugDescription: "affect must be null or a number from -1 to 1")
        }
        emergingThemes = try container.decode([String].self, forKey: .emergingThemes)
        surprisingMoments = try container.decode([String].self, forKey: .surprisingMoments)
        claims = try container.decode([DreamClaim].self, forKey: .claims)
        let raw = try decoder.container(keyedBy: JSONKey.self)
        var untouched = Set(raw.allKeys)
        var fields: [String: JSONValue] = [:]
        var counts: Drops = (0, 0)
        func checked<T>(_ key: CodingKeys, maximum: Int,
                        transform: (JSONValue) -> T?) throws -> [T] {
            untouched.remove(JSONKey(key.rawValue))
            guard container.contains(key) else { return [] }
            if try container.decodeNil(forKey: key) {
                fields[key.rawValue] = .null
                return []
            }
            guard var values = try? container.nestedUnkeyedContainer(forKey: key) else {
                counts.total += 1
                if key == .careMerges { counts.mergesMalformed += 1 }
                return []
            }
            var kept: [T] = []
            var retained: [JSONValue] = []
            while !values.isAtEnd {
                let item = try values.superDecoder()
                guard let value = (try? JSONValue(from: item)).map(DreamPart.redactOutput),
                      NativeAgentSecretRedactor.secretPath(value) == nil, let decoded = transform(value) else {
                    counts.total += 1
                    if key == .careMerges { counts.mergesMalformed += 1 }
                    continue
                }
                guard kept.count < maximum else { counts.total += 1; continue }
                kept.append(decoded)
                retained.append(value)
            }
            fields[key.rawValue] = .array(retained)
            return kept
        }
        cares = try checked(.cares, maximum: .max) { $0.stringValue }
        lessons = try checked(.lessons, maximum: 5) { value in
            guard let lesson = DreamLesson(value),
                  (try? DreamEntryProvenance.checkProse(lesson.diaryLine)) != nil else { return nil }
            return lesson
        }
        careMerges = try checked(.careMerges, maximum: 6) { value -> CognitiveCareMerge? in
            guard let fields = value.objectValue,
                  let rawIDs = fields["into_it"]?.arrayValue, !rawIDs.isEmpty, rawIDs.count <= 6,
                  let why = fields["why"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !why.isEmpty, why.count <= 500 else { return nil }
            let ids = rawIDs.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            guard ids.count == rawIDs.count, Set(ids).count == ids.count else { return nil }
            var keep: UUID?
            if let raw = fields["keep"], raw != .null {
                guard let parsed = raw.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
                keep = parsed
            }
            return CognitiveCareMerge(keep: keep, intoIt: ids, why: why)
        }
        careStanceChanges = try checked(.careStanceChanges, maximum: .max) { value -> CognitiveCareStanceChange? in
            guard let fields = value.objectValue,
                  let id = fields["care"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let rawPressure = fields["pressure"]?.arrayValue, !rawPressure.isEmpty,
                  let stance = fields["stance"]?.objectValue,
                  let text = stance["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let because = stance["because"]?.stringValue, let unless = stance["unless"]?.stringValue,
                  [text, because, unless].allSatisfy({ $0.count <= CognitiveCare.stanceCharacters }) else { return nil }
            let pressure = rawPressure.compactMap { entry -> Int? in
                guard let number = entry.exactIntegerValue, number > 0 else { return nil }
                return number
            }
            guard pressure.count == rawPressure.count, Set(pressure).count == pressure.count else { return nil }
            return CognitiveCareStanceChange(care: id, pressure: pressure,
                stance: .init(text: text, because: because, wouldChangeMind: unless))
        }
        traits = try checked(.traits, maximum: 5, transform: CognitiveSelfKnowledge.Trait.init)
        story = try checked(.story, maximum: 5, transform: CognitiveSelfKnowledge.Story.init)
        people = try checked(.people, maximum: CognitiveSelfKnowledge.maximumPeople,
            transform: CognitiveSelfKnowledge.Person.init)
        for key in untouched { fields[key.stringValue] = try raw.decode(JSONValue.self, forKey: key) }
        fields["affect"] = fields["affect"] ?? .null
        retainedFields = fields
        drops = counts

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
