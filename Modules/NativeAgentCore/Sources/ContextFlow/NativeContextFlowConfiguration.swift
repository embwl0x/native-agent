import Context
import DreamREMCycle
import Foundation
import Senses
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TurnTrace
import WorkshopExecution
import NativeAgentShared
// Blueprint: | `NativeContextFlowConfiguration.swift` | `NativeContextFlowConfiguration`, mode status, startup error and observatory health; onboarding-safe mode and RAM budget resolution |

public struct NativeContextFlowConfiguration: Sendable, Equatable {
    public static let modeEnvironmentKey = "NATIVE_AGENT_CONTEXT_FLOW_MODE"
    public static let modeDefaultsKey = "contextFlowMode"
    static let budgetDefaultsKey = "contextFlowRAMMiB"

    let mode: ContextFlowMode
    let budget: ContextArenaBudget

    public static func initializeMissingInnerLifeMode(defaults: UserDefaults) {
        guard defaults.object(forKey: modeDefaultsKey) == nil else { return }
        defaults.set(ContextFlowMode.active.rawValue, forKey: modeDefaultsKey)
    }

    static func resolve(dataRoot: URL) -> Self {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let isPublicSafe = NativeAgentPublicSafety.isPublicSafeMode(environment: environment)
        let preOnboarding = isPublicSafe
            && !NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        let explicitMode = environment[modeEnvironmentKey]
            .flatMap { ContextFlowMode(rawValue: $0.lowercased()) }
            ?? defaults.string(forKey: modeDefaultsKey)
                .flatMap { ContextFlowMode(rawValue: $0.lowercased()) }
        let mode: ContextFlowMode = preOnboarding ? .off : (explicitMode ?? .active)
        let budget = ContextArenaBudget(
            rawValue: defaults.integer(forKey: budgetDefaultsKey)
        ) ?? .default
        return Self(mode: mode, budget: budget)
    }
}

public struct NativeContextFlowModeStatus: Sendable, Equatable {
    public let effectiveMode: ContextFlowMode
}

/// Carries the startup cause to a turn that cannot proceed without context.
public struct NativeContextFlowStartupError: Error, LocalizedError {
    public let detail: String
    public var errorDescription: String? { "Context Flow could not start: \(detail)" }
}

/// Configured-off health is distinct from an unavailable runtime.
public enum ContextFlowObservatoryHealthState: Sendable, Equatable {
    case unavailable
    case off
    case health(ContextFlowCoordinatorHealth)
}
