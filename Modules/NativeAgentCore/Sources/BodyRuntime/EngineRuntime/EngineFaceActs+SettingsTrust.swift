import MacNerves
import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
// Blueprint: | `EngineFaceActs+SettingsTrust.swift` | Trust revision reads and preset acts with locked edit admission and committed policy readback |

extension EngineFaceActs {
    func readTrustRevision() async throws -> FaceActReply {
        let policy = try await engine.trust.load()
        return .result(.string(try policy.editRevision()))
    }

    func applyTrustPreset(_ request: TrustPresetRequest) async throws -> FaceActReply {
        let root = engine.dataRoot
        guard let preset = MobileTrustAction.Preset(rawValue: request.preset) else {
            throw Self.failure("trust_preset_unknown", "Choose an offered Trust preset.")
        }
        let saved = try await preset.save(dataRoot: engine.dataRoot, fullMacConfirmed: request.confirmed,
            guardedByLockedPolicy: { locked in try TrustPolicy.requireEditRevision(request.expectedRevision, policyObject: locked, dataRoot: root) })
        try await engine.settingsFeed.setPreference(.string(preset.plan.agentAccessMode), key: "chatFileAccess")
        return await trustReply(saved)
    }

    func trustReply(_ policy: TrustPolicy) async -> FaceActReply {
        await engine.trust.publishPolicy(policy)
        var value = TrustSettingsFace()
        value.policy = policy
        value.effectiveMacControlPolicy = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy)
        value.fullMacGrantIsActive = TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
        let preset = MobileTrustAction.Preset.matching(policy: policy,
            accessMode: TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy))
        value.activePreset = preset?.rawValue
        value.word = preset?.title ?? "Custom Trust"
        return .trust(value)
    }
}
