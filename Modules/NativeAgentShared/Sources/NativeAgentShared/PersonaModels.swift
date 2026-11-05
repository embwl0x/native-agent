import Foundation
// Blueprint: | `PersonaModels.swift` | Shared persona values and name validation; PersonaEngine owns identity |

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

    /// The same requirement applies before setup, repair and later profile saves.
    public static func nameValidationMessage(_ rawValue: String) -> String? {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name for the agent before saving." }
        if genericNames.contains(name.lowercased()) {
            return "Choose a specific name instead of a generic persona label."
        }
        if name.unicodeScalars.count > 80 { return "Use at most 80 code points for the agent's name." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Use a single-line name without control characters."
        }
        return nil
    }

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
    public var traits: PersonalityTraits
    public var updatedAt: String?
    /// The person's onboarding name, projected from the canonical profile.
    public var userName: String?

    public init(
        schemaVersion: Int? = nil,
        personaEngineVersion: String? = nil,
        name: String,
        personaKind: String,
        traits: PersonalityTraits,
        updatedAt: String? = nil,
        userName: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.personaEngineVersion = personaEngineVersion
        self.name = name
        self.personaKind = personaKind
        self.traits = traits
        self.updatedAt = updatedAt
        self.userName = userName
    }
}
