import Foundation

/// Presentation-only preferences for the optional Journey experience.
///
/// These keys never gate runtime owners. MemoryV2, Fluid Context, cognition,
/// Organism, TrustCenter, Workshop, and TriggerScheduler continue to run from
/// their canonical configuration whether this UI is visible or not.
enum NativeExperienceFeature: String, CaseIterable, Sendable {
    case journey
    case context
    case projects
    case automations
    case capabilities
    case lineage
    case workbench
    case diagnostics
    case kits
    case remoteNodes
    case skillEvolution
}

enum NativeExperiencePreferences {
    static let masterKey = "nativeagent.experience.enabled"
    static let journeyKey = "nativeagent.experience.journey"
    static let contextKey = "nativeagent.experience.context"
    static let projectsKey = "nativeagent.experience.projects"
    static let automationsKey = "nativeagent.experience.automations"
    static let capabilitiesKey = "nativeagent.experience.capabilities"
    static let lineageKey = "nativeagent.experience.lineage"
    static let workbenchKey = "nativeagent.experience.workbench"
    static let diagnosticsKey = "nativeagent.experience.diagnostics"
    static let kitsKey = "nativeagent.experience.kits"
    static let remoteNodesKey = "nativeagent.experience.remote-nodes"
    static let skillEvolutionKey = "nativeagent.experience.skill-evolution"

    static func key(for feature: NativeExperienceFeature) -> String {
        switch feature {
        case .journey: journeyKey
        case .context: contextKey
        case .projects: projectsKey
        case .automations: automationsKey
        case .capabilities: capabilitiesKey
        case .lineage: lineageKey
        case .workbench: workbenchKey
        case .diagnostics: diagnosticsKey
        case .kits: kitsKey
        case .remoteNodes: remoteNodesKey
        case .skillEvolution: skillEvolutionKey
        }
    }

    /// Fresh installs keep the classic presentation. Once the master switch is
    /// enabled, every section defaults on unless the user explicitly hid it.
    static func isEnabled(
        _ feature: NativeExperienceFeature,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: masterKey) else { return false }
        let featureKey = key(for: feature)
        return defaults.object(forKey: featureKey) == nil
            ? true
            : defaults.bool(forKey: featureKey)
    }

    static func enableAll(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: masterKey)
        for feature in NativeExperienceFeature.allCases {
            defaults.set(true, forKey: key(for: feature))
        }
    }

    /// Restores the pre-Journey presentation without touching any canonical
    /// data, capability, provider, schedule, subconscious, or context setting.
    static func returnToClassic(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: masterKey)
        for feature in NativeExperienceFeature.allCases {
            defaults.removeObject(forKey: key(for: feature))
        }
    }
}
