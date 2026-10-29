import Foundation
// Blueprint: | `PersonaModels.swift` | Shared personality traits, saved profile and identity-neutral display names; PersonaEngine owns canonical storage |

public struct PersonalityTraits: Codable, Hashable, Sendable {
    public var warmth: Double
    public var directness: Double
    public var humor: Double
    public var proactivity: Double
    public var rigor: Double
    public var autonomy: Double
    public var creativity: Double
    public var brevity: Double

    public init(warmth: Double, directness: Double, humor: Double, proactivity: Double,
                rigor: Double, autonomy: Double, creativity: Double, brevity: Double) {
        self.warmth = warmth
        self.directness = directness
        self.humor = humor
        self.proactivity = proactivity
        self.rigor = rigor
        self.autonomy = autonomy
        self.creativity = creativity
        self.brevity = brevity
    }
}

/// Shared display formatting excludes generic onboarding labels; PersonaEngine owns canonical identity.
public enum NativeAgentIdentity {
    private static let genericNames: Set<String> = ["agent", "custom", "ai", "male", "female"]

    public static func displayName(
        _ rawValue: String?,
        fallback: String = "NativeAgent"
    ) -> String {
        let name = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !genericNames.contains(name.lowercased()) else {
            return fallback
        }
        let scalars = name.unicodeScalars
        guard scalars.count > 80 else { return name }
        return String(String.UnicodeScalarView(scalars.prefix(80)))
    }
}

/// The saved personality profile shared by Mac and iPhone.
public struct PersonalityProfile: Codable, Hashable, Sendable {
    public var schemaVersion: Int?
    public var personaEngineVersion: String?
    public var name: String
    public var personaKind: String
    public var essence: String
    public var voice: String
    public var customDirective: String?
    public var traits: PersonalityTraits
    public var examples: [String]?
    public var forbiddenPatterns: [String]?
    public var instincts: [String]?
    public var boundaries: [String]?
    public var surfaceOverrides: [String: String]?
    public var updatedAt: String?

    public init(
        schemaVersion: Int? = nil,
        personaEngineVersion: String? = nil,
        name: String,
        personaKind: String,
        essence: String,
        voice: String,
        customDirective: String? = nil,
        traits: PersonalityTraits,
        examples: [String]? = nil,
        forbiddenPatterns: [String]? = nil,
        instincts: [String]? = nil,
        boundaries: [String]? = nil,
        surfaceOverrides: [String: String]? = nil,
        updatedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.personaEngineVersion = personaEngineVersion
        self.name = name
        self.personaKind = personaKind
        self.essence = essence
        self.voice = voice
        self.customDirective = customDirective
        self.traits = traits
        self.examples = examples
        self.forbiddenPatterns = forbiddenPatterns
        self.instincts = instincts
        self.boundaries = boundaries
        self.surfaceOverrides = surfaceOverrides
        self.updatedAt = updatedAt
    }
}
