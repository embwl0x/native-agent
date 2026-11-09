import Foundation
import NativeAgentShared
// Blueprint: | `TrustActions.swift` | Trust preset presentation and committed policy replies |

enum TrustCenterActionOutcome: Equatable {
    case saved(String)
    case failed(String)
}

@MainActor
enum TrustPolicyPresetAction {
    enum Outcome {
        case confirmationRequired
        case applied(TrustPolicy)
        case failed(String)
    }
    static func apply(_ preset: MobileTrustAction.Preset, appModel: AppModel, fullMacConfirmed: Bool = false) async -> Outcome {
        if preset == .fullMac, !fullMacConfirmed { return .confirmationRequired }
        do {
            let reply = try await appModel.checkedFaceAct(.applyTrustPreset(.init(
                preset: preset.rawValue, confirmed: fullMacConfirmed, expectedRevision: try appModel.trustEditRevision())))
            guard case .trust(let saved) = reply, let policy = saved.policy else {
                throw PartCallError(code: "trust_unconfirmed", message: "The preset has no committed policy readback.")
            }
            appModel.trustCenterActionOutcome = .saved("Trust preset saved: " + preset.title)
            return .applied(policy)
        } catch {
            appModel.recordTrustActionFailure(error.localizedDescription, cause: error)
            return .failed(error.localizedDescription)
        }
    }
}

enum TrustPolicyPresetActionPresentation {
    static func statusText(for outcome: TrustPolicyPresetAction.Outcome) -> String {
        switch outcome {
        case .confirmationRequired: "Full Mac access needs confirmation."
        case .applied: "Trust preset applied."
        case .failed(let detail): detail
        }
    }
}
