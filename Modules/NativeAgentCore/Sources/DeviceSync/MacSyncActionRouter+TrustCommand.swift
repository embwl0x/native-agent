import Foundation
import NativeAgentShared
import TrustCenter
import MacControl

extension MobileTrustAction {
    public func apply(
        dataRoot: URL,
        savePreset: @Sendable (Preset, Bool) async throws -> TrustPolicy
    ) async throws -> TrustPolicy {
        // Revalidate even when a caller constructs the enum directly.
        guard let validated = MobileTrustAction(payload: payload) else {
            throw MobileTrustActionError.invalidRequest
        }
        let saved: TrustPolicy
        switch validated {
        case .preset(let preset, let confirmed):
            saved = try await savePreset(preset, confirmed)
        case .policy(.permissionLevel, let value, _):
            guard let preset = MobileTrustAction.Preset(permissionLevel: value) else {
                throw MobileTrustActionError.invalidRequest
            }
            saved = try await savePreset(preset, false)
        case .policy(let field, let value, _):
            let body: [String: Any]
            switch field {
            case .permissionLevel: throw MobileTrustActionError.invalidRequest
            case .autonomyDefault: body = [field.rawValue: value]
            case .requireBackups: body = ["filePolicy": ["requireBackupBeforeWrite": value == "true"]]
            case .outsideDefault: body = ["filePolicy": ["outsideWorkspaceDefault": value]]
            case .developerMode:
                body = TrustPolicyActions.developerModePatchBody(enabled: value == "true")
            case .workshopEnabled: body = ["missionPolicy": ["enabled": value == "true"]]
            case .showTimeline: body = ["missionPolicy": ["showTimeline": value == "true"]]
            case .autonomousTraining: throw MobileTrustActionError.trainingUnavailable
            case .dreamScheduler: body = ["trainingPolicy": ["dream_scheduler": value == "true"]]
            }
            saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: body, dataRoot: dataRoot,
                guardedByLockedPolicy: { locked in
                    if field == .outsideDefault,
                       let trust = MacControlPolicy.fromTrustPolicyObject(locked).trustPolicy,
                       MacControlGate.fullMacActive(trust) {
                        throw MobileTrustActionError.outsideFullMac
                    }
                }
            )
        }
        return saved
    }
}

private enum MobileTrustActionError: LocalizedError {
    case invalidRequest
    case trainingUnavailable
    case outsideFullMac
    var errorDescription: String? {
        switch self {
        case .trainingUnavailable: "Autonomous training is no longer available."
        case .invalidRequest: "Invalid or unconfirmed trust change."
        case .outsideFullMac: MobileTrustAction.outsideFullMacRefusal
        }
    }
}
