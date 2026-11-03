import Context
import CoreFoundation
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
// Blueprint: | `NativeContextFlowConfiguration.swift` | `NativeContextFlowConfiguration`, checked mode/budget resolution, mode status, startup error and observatory health; invalid settings remain unavailable, absent settings use the documented defaults; onboarding-safe mode and RAM budget resolution |

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

    static func resolve(dataRoot: URL) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let isPublicSafe = NativeAgentPublicSafety.isPublicSafeMode(environment: environment)
        let preOnboarding = isPublicSafe
            && !NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        // Validate every present setting, even under an environment override or
        // before onboarding. Only absence supplies a default.
        let savedMode: ContextFlowMode?
        if let raw = defaults.object(forKey: modeDefaultsKey) {
            guard let value = raw as? String, let parsed = ContextFlowMode(rawValue: value) else {
                throw NativeContextFlowStartupError(detail: "Invalid saved \(modeDefaultsKey); choose off or active in Settings.")
            }
            savedMode = parsed
        } else { savedMode = nil }
        let environmentMode: ContextFlowMode?
        if let raw = environment[modeEnvironmentKey] {
            guard let parsed = ContextFlowMode(rawValue: raw) else {
                throw NativeContextFlowStartupError(detail: "Invalid \(modeEnvironmentKey); use off or active.")
            }
            environmentMode = parsed
        } else { environmentMode = nil }
        let mode: ContextFlowMode = preOnboarding ? .off : (environmentMode ?? savedMode ?? .active)
        let budget: ContextArenaBudget
        if let raw = defaults.object(forKey: budgetDefaultsKey) {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = Int(exactly: number.doubleValue),
                  let parsed = ContextArenaBudget(rawValue: integer) else {
                throw NativeContextFlowStartupError(detail: "Invalid saved \(budgetDefaultsKey); use 32, 64, 96, 128 or 256 MiB.")
            }
            budget = parsed
        } else { budget = .default }
        return Self(mode: mode, budget: budget)
    }
}

public struct NativeContextFlowModeStatus: Sendable, Equatable {
    public let effectiveMode: ContextFlowMode?
    public let unavailableReason: String?
}

/// Carries the startup cause to a turn that cannot proceed without context.
public struct NativeContextFlowStartupError: Error, LocalizedError, Sendable, Equatable {
    public let detail: String
    public var errorDescription: String? { "Context Flow could not start: \(detail)" }
}

/// Configured-off health is distinct from an unavailable runtime.
public enum ContextFlowObservatoryHealthState: Sendable, Equatable {
    case unavailable
    case off
    case health(ContextFlowCoordinatorHealth)
}
