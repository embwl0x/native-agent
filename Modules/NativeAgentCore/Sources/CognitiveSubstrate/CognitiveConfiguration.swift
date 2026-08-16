import Foundation

public struct CognitiveConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var persistenceEnabled: Bool
    public var workspaceEnabled: Bool
    public var capsuleInjectionEnabled: Bool
    /// Canary for relevance-gating the durable standing-view `Inner` line.
    /// Turning this off restores the prior most-recent-active-view behavior
    /// without changing any persisted view or appraisal influence.
    public var standingViewCapsuleRelevanceEnabled: Bool
    public var affectEnabled: Bool
    public var thoughtSeedsEnabled: Bool
    public var replayEnabled: Bool
    public var backgroundMicrocyclesEnabled: Bool
    public var reflectiveCallsEnabled: Bool
    public var observatoryEnabled: Bool
    public var maximumActiveNodes: Int
    public var defaultDecayHalfLife: TimeInterval
    public var maximumMetadataKeys: Int
    public var maximumMetadataStringCharacters: Int
    public var maximumSummaryCharacters: Int
    public var maximumCapsuleCharacters: Int
    public var maximumWorkspaceItems: Int
    public var maximumThoughtSeeds: Int
    public var dailyReflectionCallBudget: Int
    public var reflectionSurface: String
    public var reflectionModel: String
    public var reflectionProvider: String
    public var reflectionReasoningEffort: String

    public init(
        enabled: Bool = false,
        persistenceEnabled: Bool = false,
        workspaceEnabled: Bool = false,
        capsuleInjectionEnabled: Bool = false,
        standingViewCapsuleRelevanceEnabled: Bool = true,
        affectEnabled: Bool = false,
        thoughtSeedsEnabled: Bool = false,
        replayEnabled: Bool = false,
        backgroundMicrocyclesEnabled: Bool = false,
        reflectiveCallsEnabled: Bool = false,
        observatoryEnabled: Bool = false,
        maximumActiveNodes: Int = 256,
        defaultDecayHalfLife: TimeInterval = 60 * 60,
        maximumMetadataKeys: Int = 12,
        maximumMetadataStringCharacters: Int = 500,
        maximumSummaryCharacters: Int = 500,
        maximumCapsuleCharacters: Int = 1800,
        maximumWorkspaceItems: Int = 12,
        maximumThoughtSeeds: Int = 128,
        dailyReflectionCallBudget: Int = 0,
        reflectionSurface: String = "cognition_reflection",
        reflectionModel: String = "claude-opus-4-8",
        reflectionProvider: String = "anthropic_oauth_direct",
        reflectionReasoningEffort: String = "high"
    ) {
        self.enabled = enabled
        self.persistenceEnabled = persistenceEnabled
        self.workspaceEnabled = workspaceEnabled
        self.capsuleInjectionEnabled = capsuleInjectionEnabled
        self.standingViewCapsuleRelevanceEnabled = standingViewCapsuleRelevanceEnabled
        self.affectEnabled = affectEnabled
        self.thoughtSeedsEnabled = thoughtSeedsEnabled
        self.replayEnabled = replayEnabled
        self.backgroundMicrocyclesEnabled = backgroundMicrocyclesEnabled
        self.reflectiveCallsEnabled = reflectiveCallsEnabled
        self.observatoryEnabled = observatoryEnabled
        self.maximumActiveNodes = max(1, maximumActiveNodes)
        self.defaultDecayHalfLife = max(1, defaultDecayHalfLife)
        self.maximumMetadataKeys = max(0, maximumMetadataKeys)
        self.maximumMetadataStringCharacters = max(0, maximumMetadataStringCharacters)
        self.maximumSummaryCharacters = max(0, maximumSummaryCharacters)
        self.maximumCapsuleCharacters = max(0, maximumCapsuleCharacters)
        self.maximumWorkspaceItems = max(1, maximumWorkspaceItems)
        self.maximumThoughtSeeds = max(0, maximumThoughtSeeds)
        self.dailyReflectionCallBudget = max(0, dailyReflectionCallBudget)
        self.reflectionSurface = Self.cleaned(reflectionSurface, fallback: "cognition_reflection")
        self.reflectionModel = Self.cleaned(reflectionModel, fallback: "claude-opus-4-8")
        self.reflectionProvider = Self.cleaned(reflectionProvider, fallback: "anthropic_oauth_direct")
        self.reflectionReasoningEffort = Self.cleaned(reflectionReasoningEffort, fallback: "high")
    }

    public static let disabled = CognitiveConfiguration(enabled: false)

    public static let phaseOneEnabled = CognitiveConfiguration(enabled: true)

    public static let allPhasesEnabled = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        thoughtSeedsEnabled: true,
        replayEnabled: true,
        backgroundMicrocyclesEnabled: true,
        reflectiveCallsEnabled: true,
        observatoryEnabled: true,
        dailyReflectionCallBudget: 2
    )

    private static func cleaned(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
