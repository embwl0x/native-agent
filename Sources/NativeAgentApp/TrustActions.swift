import AppToolRuntime
import EngineRuntime
import Foundation
import NativeAgentShared
import PersistenceCore
import SwiftUI
import TrustCenter
// Blueprint: | `TrustActions.swift` | Shared Trust preset commands, action outcomes, navigation keys and Telegram status tone; Trust draws its core face |

enum TrustCenterActionOutcome: Equatable {
    case saved(String)
    case failed(String)
}

enum TrustTab: String, CaseIterable {
    case access = "trust"
    case features
    case macAndBrowser = "mac"
    case advanced
}

@MainActor
enum TrustPolicyPresetAction {
    typealias Outcome = MobileTrustAction.Preset.Outcome

    static func apply(
        _ preset: MobileTrustAction.Preset,
        appModel: AppModel,
        fullMacConfirmed: Bool = false,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async -> Outcome {
        let plan = preset.plan
        let policy: TrustPolicy
        do {
            let outcome = try await preset.apply(
                dataRoot: appModel.firstRunDataRoot,
                fullMacConfirmed: fullMacConfirmed,
                guardedByLockedPolicy: guardedByLockedPolicy
            )
            guard case .applied(let savedPolicy) = outcome else { return outcome }
            policy = savedPolicy
        } catch {
            let detail = UserFacingError.message(error, action: "apply that trust preset")
            appModel.recordTrustActionFailure(detail)
            return .failed(detail)
        }
        appModel.applySavedTrustPolicy(
            policy, status: "Trust preset saved: \(preset.title)")
        appModel.chatFileAccess = TrustAccessModeCapabilityCatalog.normalizedMode(plan.agentAccessMode)
        // Preserve the post-save app refresh for presets that change multiple axes.
        if plan.commit == .accessModeThenTrustPolicy {
            await appModel.refreshAll()
        }
        return .applied(policy)
    }
}

enum TrustPolicyPresetActionPresentation {
    static func statusText(for outcome: TrustPolicyPresetAction.Outcome) -> String {
        switch outcome {
        case .confirmationRequired:
            return "Full Mac access needs confirmation."
        case .applied:
            return "Trust preset applied."
        case .failed(let detail):
            return detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Trust preset could not be applied."
                : detail
        }
    }
}


// MARK: - Page kit

enum TrustTone: Equatable {
    case calm
    case trouble
    case quiet

    var color: Color {
        switch self {
        case .calm: NativeAgentShell.calm
        case .trouble: NativeAgentShell.trouble
        case .quiet: NativeAgentShell.secondary
        }
    }

}
