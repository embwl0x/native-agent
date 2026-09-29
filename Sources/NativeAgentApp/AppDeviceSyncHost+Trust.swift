import AppToolRuntime
import Foundation
import NativeAgentShared
import PersistenceCore
import TrustCenter

extension AppDeviceSyncHost {
    func applyMobileTrustAction(_ request: MobileTrustAction) async throws -> Data {
        // Revalidate even when a caller constructs the enum directly.
        guard let validated = MobileTrustAction(payload: request.payload) else {
            throw MobileTrustActionError.invalidRequest
        }
        let saved: TrustPolicy
        switch validated {
        case .preset(let preset, let confirmed):
            guard let canonical = TrustPolicyPreset.allCases.first(where: { $0.quietID == preset.rawValue }) else {
                throw MobileTrustActionError.invalidRequest
            }
            saved = try await NativeClient.saveTrustPreset(
                canonical, dataRoot: PersistenceCore.defaultDataRoot(), fullMacConfirmed: confirmed
            )
        case .policy(.permissionLevel, let value, _):
            guard let preset = MobileTrustAction.Preset(permissionLevel: value),
                  let canonical = TrustPolicyPreset.allCases.first(where: { $0.quietID == preset.rawValue }) else {
                throw MobileTrustActionError.invalidRequest
            }
            saved = try await NativeClient.saveTrustPreset(
                canonical, dataRoot: PersistenceCore.defaultDataRoot(), fullMacConfirmed: false
            )
        case .policy(let field, let value, _):
            let body: [String: Any]
            switch field {
            case .permissionLevel: throw MobileTrustActionError.invalidRequest
            case .autonomyDefault: body = [field.rawValue: value]
            case .requireBackups: body = ["filePolicy": ["requireBackupBeforeWrite": value == "true"]]
            case .outsideDefault: body = ["filePolicy": ["outsideWorkspaceDefault": value]]
            case .developerMode:
                body = NativeClient.developerModePatchBody(enabled: value == "true")
            case .workshopEnabled: body = ["missionPolicy": ["enabled": value == "true"]]
            case .showTimeline: body = ["missionPolicy": ["showTimeline": value == "true"]]
            case .autonomousTraining: body = ["trainingPolicy": ["autonomous_training": value == "true"]]
            case .dreamScheduler: body = ["trainingPolicy": ["dream_scheduler": value == "true"]]
            }
            saved = try await NativeClient.applyTrustPolicyPatch(
                body: body, dataRoot: PersistenceCore.defaultDataRoot(),
                guardedByLockedPolicy: { locked in
                    if field == .outsideDefault,
                       let trust = MacControlPolicy.fromTrustPolicyObject(locked).trustPolicy,
                       MacControlGate.fullMacActive(trust) {
                        throw MobileTrustActionError.outsideFullMac
                    }
                }
            )
        }
        await MainActor.run { NativeAgentEngine.live.trust.policy = saved }
        // Raw checked policy is also the existing trust_policy.json snapshot.
        return try await trustSnapshotData()
    }
}

private enum MobileTrustActionError: LocalizedError {
    case invalidRequest
    case outsideFullMac
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Invalid or unconfirmed trust change."
        case .outsideFullMac: MobileTrustAction.outsideFullMacRefusal
        }
    }
}
