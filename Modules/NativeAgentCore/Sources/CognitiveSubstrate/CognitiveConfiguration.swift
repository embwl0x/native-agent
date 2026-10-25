import Foundation

// Blueprint: | `CognitiveConfiguration.swift` | `CognitiveConfiguration`: cleaned cognition settings, reflection spend ceilings and personality experiment gates |

public struct CognitiveConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var persistenceEnabled: Bool
    public var capsuleInjectionEnabled: Bool
    public var affectEnabled: Bool { enabled }
    public var backgroundMicrocyclesEnabled: Bool
    public var reflectiveCallsEnabled: Bool
    public var observatoryEnabled: Bool { enabled }
    public var maximumActiveNodes: Int
    public var defaultDecayHalfLife: TimeInterval
    public var maximumMetadataKeys: Int
    public var maximumMetadataStringCharacters: Int
    public var maximumSummaryCharacters: Int
    public var maximumCapsuleCharacters: Int
    public var maximumWorkspaceItems: Int
    /// HARD cost ceiling on reflection calls in a ROLLING 24h window — the
    /// spend fence, NOT the trigger. Admission is unresolved load
    /// (`reflectionLoadThreshold`); this only says how much a hard day may
    /// ever spend. The name is historical: the ledger is still the reflection
    /// receipts, but the window rolls instead of resetting at midnight.
    public var dailyReflectionCallBudget: Int
    /// Admission threshold for a SPONTANEOUS reflection: unresolved load
    /// (summed pressure from live open cares) must reach this before an unattended call is
    /// admitted. A quiet day never reaches it and spends nothing. A reflection
    /// a person asked for is not gated by it — only by the ceiling.
    public var reflectionLoadThreshold: Double
    public var reflectionSurface: String
    public var reflectionModel: String
    public var reflectionProvider: String
    public var reflectionReasoningEffort: String

    public init(
        enabled: Bool = false,
        persistenceEnabled: Bool = false,
        capsuleInjectionEnabled: Bool = false,
        backgroundMicrocyclesEnabled: Bool = false,
        reflectiveCallsEnabled: Bool = false,
        maximumActiveNodes: Int = 256,
        defaultDecayHalfLife: TimeInterval = 60 * 60,
        maximumMetadataKeys: Int = 12,
        maximumMetadataStringCharacters: Int = 500,
        maximumSummaryCharacters: Int = 500,
        maximumCapsuleCharacters: Int = 1800,
        maximumWorkspaceItems: Int = 12,
        dailyReflectionCallBudget: Int = 0,
        reflectionLoadThreshold: Double = 0.35,
        reflectionSurface: String = "cognition_reflection",
        // 2026-09-13: the reflection model and route are the Memory and mind
        // group's, resolved at call time. Empty means "the group's choice".
        reflectionModel: String = "",
        reflectionProvider: String = "",
        reflectionReasoningEffort: String = "high"
    ) {
        self.enabled = enabled
        self.persistenceEnabled = persistenceEnabled
        self.capsuleInjectionEnabled = capsuleInjectionEnabled
        self.backgroundMicrocyclesEnabled = backgroundMicrocyclesEnabled
        self.reflectiveCallsEnabled = reflectiveCallsEnabled
        self.maximumActiveNodes = max(1, maximumActiveNodes)
        self.defaultDecayHalfLife = max(1, defaultDecayHalfLife)
        self.maximumMetadataKeys = max(0, maximumMetadataKeys)
        self.maximumMetadataStringCharacters = max(0, maximumMetadataStringCharacters)
        self.maximumSummaryCharacters = max(0, maximumSummaryCharacters)
        self.maximumCapsuleCharacters = max(0, maximumCapsuleCharacters)
        self.maximumWorkspaceItems = max(1, maximumWorkspaceItems)
        self.dailyReflectionCallBudget = max(0, dailyReflectionCallBudget)
        self.reflectionLoadThreshold = reflectionLoadThreshold.clamped01()
        self.reflectionSurface = Self.cleaned(reflectionSurface, fallback: "cognition_reflection")
        self.reflectionModel = Self.cleaned(reflectionModel, fallback: "")
        self.reflectionProvider = Self.cleaned(reflectionProvider, fallback: "")
        self.reflectionReasoningEffort = Self.cleaned(reflectionReasoningEffort, fallback: "high")
    }

    public static let disabled = CognitiveConfiguration(enabled: false)

    private static func cleaned(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
